#!/usr/bin/env zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir:h}"

app_path="$root_dir/dist/dwb player.app"
release_root="$root_dir/dist/release"
output_dir=""
version="4.2.2"
build="4.2.2"
skip_build=0
release_mode=0
notarize=0
allow_notarization_upload="${DWB_ALLOW_NOTARIZATION_UPLOAD:-0}"
check_release_inputs=0

usage() {
    cat <<'EOF'
Usage: scripts/package-release.sh [options]

Options:
  --app <path>          App bundle to package. Default: dist/dwb player.app
  --output-dir <path>   Release artifact directory. Default: dist/release/dwb-player-<version>
  --version <version>   Expected app/release version. Default: 4.2.2
  --build <build>       Expected bundle build number. Default: 4.2.2
  --skip-build          Package the existing app after verification
  --release             Developer ID sign, notarize, staple, and verify a public
                        binary release artifact
  --notarize            Submit for notarization; requires explicit upload
                        permission and credentials
  --allow-notarization-upload
                        Permit xcrun notarytool submit for this invocation
  --check-release-inputs
                        Validate release signing/notary inputs and exit without
                        building, packaging, signing, notarizing, or uploading
  --help                Show this help text

By default this script runs ./scripts/build-app.sh before packaging.
It creates a local ZIP, SHA-256 file, manifest JSON, and release notes draft.
It does not create a GitHub release, upload assets, notarize, staple, tag, or commit.

Public binary release mode is opt-in. It requires DWB_SIGNING_IDENTITY to name
an installed Developer ID Application identity and requires either
DWB_NOTARY_KEYCHAIN_PROFILE or the documented DWB_NOTARY_APPLE_ID,
DWB_NOTARY_TEAM_ID, and DWB_NOTARY_PASSWORD variables. Secret values are never
printed. Notarization upload requires --release or --notarize plus
--allow-notarization-upload or DWB_ALLOW_NOTARIZATION_UPLOAD=1.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            if [[ $# -lt 2 || -z "$2" ]]; then
                printf "ERROR: --app requires a path.\n" >&2
                exit 2
            fi
            app_path="$2"
            shift 2
            ;;
        --output-dir)
            if [[ $# -lt 2 || -z "$2" ]]; then
                printf "ERROR: --output-dir requires a path.\n" >&2
                exit 2
            fi
            output_dir="$2"
            shift 2
            ;;
        --version)
            if [[ $# -lt 2 || -z "$2" ]]; then
                printf "ERROR: --version requires a value.\n" >&2
                exit 2
            fi
            version="$2"
            shift 2
            ;;
        --build)
            if [[ $# -lt 2 || -z "$2" ]]; then
                printf "ERROR: --build requires a value.\n" >&2
                exit 2
            fi
            build="$2"
            shift 2
            ;;
        --skip-build)
            skip_build=1
            shift
            ;;
        --release)
            release_mode=1
            notarize=1
            shift
            ;;
        --notarize)
            notarize=1
            release_mode=1
            shift
            ;;
        --allow-notarization-upload)
            allow_notarization_upload=1
            shift
            ;;
        --check-release-inputs)
            check_release_inputs=1
            release_mode=1
            notarize=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf "ERROR: Unknown option: %s\n" "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf "ERROR: Required tool not found: %s\n" "$tool" >&2
        exit 1
    fi
}

plist_value() {
    local key="$1"
    local plist="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist"
}

verify_app_version() {
    local candidate_app="$1"
    local info_plist="$candidate_app/Contents/Info.plist"

    if [[ ! -d "$candidate_app" ]]; then
        printf "ERROR: App bundle not found: %s\n" "$candidate_app" >&2
        exit 1
    fi

    if [[ ! -f "$info_plist" ]]; then
        printf "ERROR: Info.plist not found: %s\n" "$info_plist" >&2
        exit 1
    fi

    local actual_version actual_build
    actual_version="$(plist_value CFBundleShortVersionString "$info_plist")"
    actual_build="$(plist_value CFBundleVersion "$info_plist")"

    printf "App version:     %s\n" "$actual_version"
    printf "Bundle version:  %s\n" "$actual_build"

    if [[ "$actual_version" != "$version" ]]; then
        printf "ERROR: App version is '%s', expected '%s'.\n" "$actual_version" "$version" >&2
        exit 1
    fi

    if [[ "$actual_build" != "$build" ]]; then
        printf "ERROR: Bundle version is '%s', expected '%s'.\n" "$actual_build" "$build" >&2
        exit 1
    fi
}

json_string() {
    /usr/bin/python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

require_tool ditto
require_tool shasum
require_tool codesign
require_tool spctl
require_tool stat
require_tool touch
require_tool find
require_tool sort
require_tool python3

have_notary_profile() {
    [[ -n "${DWB_NOTARY_KEYCHAIN_PROFILE:-}" ]]
}

have_notary_apple_id_credentials() {
    [[ -n "${DWB_NOTARY_APPLE_ID:-}" && -n "${DWB_NOTARY_TEAM_ID:-}" && -n "${DWB_NOTARY_PASSWORD:-}" ]]
}

validate_notary_inputs() {
    require_tool xcrun

    if ! xcrun notarytool --help >/dev/null 2>&1; then
        printf "ERROR: xcrun notarytool is unavailable.\n" >&2
        exit 1
    fi
    if ! xcrun -f stapler >/dev/null 2>&1; then
        printf "ERROR: xcrun stapler is unavailable.\n" >&2
        exit 1
    fi

    if have_notary_profile; then
        printf "Notary credentials: keychain profile present\n"
    elif have_notary_apple_id_credentials; then
        printf "Notary credentials: Apple ID/team/password variables present\n"
    else
        printf "ERROR: Notarization requires DWB_NOTARY_KEYCHAIN_PROFILE or DWB_NOTARY_APPLE_ID, DWB_NOTARY_TEAM_ID, and DWB_NOTARY_PASSWORD.\n" >&2
        exit 1
    fi
}

validate_release_inputs() {
    if [[ -z "${DWB_SIGNING_IDENTITY:-}" ]]; then
        printf "ERROR: Public release packaging requires DWB_SIGNING_IDENTITY with a Developer ID Application identity.\n" >&2
        exit 1
    fi

    zsh "$root_dir/scripts/sign-app.sh" \
        --identity "$DWB_SIGNING_IDENTITY" \
        --release \
        --check-release-inputs

    validate_notary_inputs

    if [[ "$notarize" -eq 1 && "$allow_notarization_upload" != "1" ]]; then
        printf "ERROR: Notarization upload is disabled.\n" >&2
        printf "Set DWB_ALLOW_NOTARIZATION_UPLOAD=1 or pass --allow-notarization-upload for an authorized credentialed release pass.\n" >&2
        exit 1
    fi
}

submit_zip_for_notarization() {
    local candidate_zip="$1"

    if have_notary_profile; then
        xcrun notarytool submit "$candidate_zip" \
            --keychain-profile "$DWB_NOTARY_KEYCHAIN_PROFILE" \
            --wait
    else
        xcrun notarytool submit "$candidate_zip" \
            --apple-id "$DWB_NOTARY_APPLE_ID" \
            --team-id "$DWB_NOTARY_TEAM_ID" \
            --password "$DWB_NOTARY_PASSWORD" \
            --wait
    fi
}

app_path="${app_path:A}"
artifact_base="dwb-player-${version}"
if [[ -z "$output_dir" ]]; then
    output_dir="$release_root/$artifact_base"
fi
output_dir="${output_dir:A}"
zip_name="${artifact_base}-macos.zip"
sha_name="${zip_name}.sha256"
notes_name="${artifact_base}-release-notes.md"
manifest_name="${artifact_base}-manifest.json"
zip_path="$output_dir/$zip_name"
sha_path="$output_dir/$sha_name"
notes_path="$output_dir/$notes_name"
manifest_path="$output_dir/$manifest_name"
zip_check_path="${zip_path#$root_dir/}"
staging_root="$root_dir/.tmp/package-release"
staging_parent="$staging_root/stage"
staged_app="$staging_parent/dwb player.app"
verify_root="$root_dir/.tmp/package-verify"
extracted_app="$verify_root/dwb player.app"
build_info_path="$root_dir/dist/dwb-player-app-build-info.txt"
configuration="${DWB_CONFIGURATION:-Release}"
source_date_epoch="${SOURCE_DATE_EPOCH:-946684800}"
source_touch_time="$(TZ=UTC date -r "$source_date_epoch" '+%Y%m%d%H%M.%S')"

if [[ "$check_release_inputs" -eq 1 ]]; then
    validate_release_inputs
    printf "Release packaging input check passed.\n"
    exit 0
fi

if [[ "$release_mode" -eq 1 || "$notarize" -eq 1 ]]; then
    validate_release_inputs
fi

if [[ "$skip_build" -eq 0 ]]; then
    printf "Building app before packaging...\n"
    if [[ "$release_mode" -eq 1 ]]; then
        DWB_RELEASE_SIGN=1 "$root_dir/scripts/build-app.sh"
    else
        "$root_dir/scripts/build-app.sh"
    fi
else
    printf "Skipping build; packaging existing app.\n"
fi

printf "Verifying source app: %s\n" "$app_path"
verify_app_version "$app_path"
if [[ "$release_mode" -eq 1 ]]; then
    "$root_dir/scripts/sign-app.sh" --app "$app_path" --identity "$DWB_SIGNING_IDENTITY" --release
else
    "$root_dir/scripts/sign-app.sh" --app "$app_path" --verify-only
fi

if [[ -f "$build_info_path" ]]; then
    build_configuration="$(awk -F= '/^configuration=/ { print $2; exit }' "$build_info_path" 2>/dev/null || true)"
    if [[ -n "$build_configuration" ]]; then
        configuration="$build_configuration"
    fi
fi

mkdir -p "$output_dir" "$staging_parent" "$verify_root"
rm -rf "$staged_app" "$verify_root"
mkdir -p "$staging_parent" "$verify_root"
rm -f "$zip_path" "$sha_path" "$notes_path" "$manifest_path"

printf "Staging app for ZIP packaging...\n"
ditto --noqtn "$app_path" "$staged_app"

while IFS= read -r item; do
    touch -h -t "$source_touch_time" "$item"
done < <(find "$staged_app" -depth -print | sort)

printf "Creating ZIP: %s\n" "$zip_path"
(cd "$staging_parent" && ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 "dwb player.app" "$zip_path")

if [[ ! -s "$zip_path" ]]; then
    printf "ERROR: ZIP was not created or is empty: %s\n" "$zip_path" >&2
    exit 1
fi

sha256="$(shasum -a 256 "$zip_path" | awk '{ print $1 }')"
artifact_size_bytes="$(stat -f '%z' "$zip_path")"
printf "%s  %s\n" "$sha256" "$zip_check_path" > "$sha_path"

printf "Verifying checksum file...\n"
(cd "$root_dir" && shasum -a 256 -c "$sha_path")

printf "Extracting ZIP for verification...\n"
ditto -x -k "$zip_path" "$verify_root"
verify_app_version "$extracted_app"

printf "Verifying extracted app signature...\n"
if codesign --verify --deep --strict --verbose=4 "$extracted_app" 2>&1; then
    signing_status="codesign strict verification passed for source and extracted apps"
else
    printf "ERROR: Extracted app failed codesign verification.\n" >&2
    exit 1
fi

printf "Assessing extracted app with spctl...\n"
set +e
gatekeeper_output="$(spctl -a -vv "$extracted_app" 2>&1)"
gatekeeper_code=$?
set -e
if [[ "$gatekeeper_code" -eq 0 ]]; then
    gatekeeper_status="accepted: ${gatekeeper_output}"
else
    gatekeeper_status="rejected or unavailable (exit ${gatekeeper_code}): ${gatekeeper_output}"
fi
printf "%s\n" "$gatekeeper_status"

notarization_status="not notarized; not stapled"
source_commit="$(git -C "$root_dir" rev-parse HEAD 2>/dev/null || printf "unavailable")"
created_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ "$notarize" -eq 1 ]]; then
    printf "Submitting ZIP for notarization: %s\n" "$zip_path"
    submit_zip_for_notarization "$zip_path"

    printf "Stapling notarization ticket to staged app...\n"
    xcrun stapler staple "$staged_app"
    xcrun stapler validate "$staged_app"

    printf "Recreating ZIP with stapled app...\n"
    rm -f "$zip_path" "$sha_path"
    (cd "$staging_parent" && ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 "dwb player.app" "$zip_path")
    sha256="$(shasum -a 256 "$zip_path" | awk '{ print $1 }')"
    artifact_size_bytes="$(stat -f '%z' "$zip_path")"
    printf "%s  %s\n" "$sha256" "$zip_check_path" > "$sha_path"
    (cd "$root_dir" && shasum -a 256 -c "$sha_path")

    printf "Submitting final stapled ZIP for notarization confirmation: %s\n" "$zip_path"
    submit_zip_for_notarization "$zip_path"

    rm -rf "$verify_root"
    mkdir -p "$verify_root"
    ditto -x -k "$zip_path" "$verify_root"
    verify_app_version "$extracted_app"
    codesign --verify --deep --strict --verbose=4 "$extracted_app" 2>&1
    xcrun stapler validate "$extracted_app"

    printf "Assessing stapled extracted app with spctl...\n"
    set +e
    gatekeeper_output="$(spctl -a -vv "$extracted_app" 2>&1)"
    gatekeeper_code=$?
    set -e
    if [[ "$gatekeeper_code" -eq 0 ]]; then
        gatekeeper_status="accepted: ${gatekeeper_output}"
    else
        printf "ERROR: Gatekeeper rejected the notarized release app.\n" >&2
        printf "%s\n" "$gatekeeper_output" >&2
        exit 1
    fi
    notarization_status="notarized and stapled"
fi

cat > "$notes_path" <<EOF
# dwb player v${version}

## Overview

This is a local draft release note for the dwb player ${version} macOS ZIP artifact. It has not been uploaded or published.

## Highlights

- Native AppKit local media playback for macOS 13 and newer.
- VLCKit-backed video playback with support for common local video formats: mp4, m4v, mov, avi, flv, f4v, wmv, asf, mkv, ts, mts, m2ts, m2t, mpg, 3gp, 3g2, vob, ogv, and ogm.
- Still-image and animated GIF playback for jpg/jpeg, jfif, png, gif, tiff/tif, bmp, heic, heif, and webp.
- Queue Page, search/filter, total duration, quick queueing, shuffle/endless shuffle, repeat one, and multi-window playback.
- Four Window Grid layout, bottom rail controls, Settings, and local file workflow controls.
- Dual configurable prefix rename works for videos, images, and GIFs: Q applies the primary prefix and Option-Q applies the secondary prefix.
- Folder import and Queue Page Name A-Z / Name Z-A sorting use Finder-style natural filename ordering.
- Multi-window autoplay transitions reuse the current VLCKit player during normal auto-advance to reduce the risk of VLCKit configuration lock hangs.

## Feature Groups

- Playback: local video playback, image/GIF viewing, seek controls, volume, fullscreen, scaling, repeat, and shuffle modes.
- Queue: sortable Queue Page, search/filter, multi-select removal, selected-row Delete/Backspace removal, drag ordering, total duration, Reveal in Finder, bookmark filtering, and dual-prefix rename.
- Windows: independent player windows, per-window playback state, opacity, on-top mode, titlebar behavior, and four-window arrangement.
- Settings: playback, controls, queue/file behavior, titlebar, rail, opacity, and developer/debug options.
- Unsupported: this release does not claim .ogg support.

## Signing And Notarization Status

- Signing status: ${signing_status}.
- Notarization status: ${notarization_status}.
- Gatekeeper status: ${gatekeeper_status}.

## Install And Open Note

Extract \`${zip_name}\` to produce \`dwb player.app\`. Local ad-hoc ZIPs are for local verification only and can be rejected by macOS Gatekeeper. Public binary use requires a Developer ID signed, notarized, stapled, and Gatekeeper-verified artifact.

## Checksum

\`\`\`text
SHA-256 (${zip_name}) = ${sha256}
\`\`\`

Checksum file:

\`\`\`text
${sha_name}
\`\`\`

## Known Limitations

- No GitHub Release, tag, upload, or public release asset was created for this draft.
- No installer package is included in this ZIP workflow.
- Manual launch/playback checks remain required after extraction.
- Gatekeeper acceptance is expected only for artifacts produced with \`--release\` and verified successfully after extraction.
EOF

cat > "$manifest_path" <<EOF
{
  "app_name": $(json_string "dwb player"),
  "version": $(json_string "$version"),
  "build": $(json_string "$build"),
  "configuration": $(json_string "$configuration"),
  "artifact_name": $(json_string "$zip_name"),
  "artifact_path": $(json_string "$zip_path"),
  "artifact_size_bytes": $artifact_size_bytes,
  "sha256": $(json_string "$sha256"),
  "supported_video_extensions": [
    "mp4", "m4v", "mov", "avi", "flv", "f4v", "wmv", "asf", "mkv",
    "ts", "mts", "m2ts", "m2t", "mpg", "3gp", "3g2", "vob", "ogv", "ogm"
  ],
  "supported_image_extensions": [
    "jpg", "jpeg", "jfif", "png", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp"
  ],
  "rename_features": [
    "primary custom-prefix rename for videos, images, and GIFs",
    "secondary custom-prefix rename for videos, images, and GIFs"
  ],
  "ogg_support_claimed": false,
  "created_utc": $(json_string "$created_utc"),
  "signing_status": $(json_string "$signing_status"),
  "notarization_status": $(json_string "$notarization_status"),
  "gatekeeper_status": $(json_string "$gatekeeper_status"),
  "source_commit": $(json_string "$source_commit")
}
EOF

python3 -m json.tool "$manifest_path" >/dev/null

if [[ ! -s "$sha_path" || ! -s "$notes_path" || ! -s "$manifest_path" ]]; then
    printf "ERROR: One or more release sidecar artifacts are missing or empty.\n" >&2
    exit 1
fi

printf "\nRelease artifacts written to %s\n" "$output_dir"
printf "ZIP:            %s\n" "$zip_path"
printf "SHA-256:        %s\n" "$sha256"
printf "Checksum file:  %s\n" "$sha_path"
printf "Manifest:       %s\n" "$manifest_path"
printf "Release notes:  %s\n" "$notes_path"
printf "Gatekeeper:     %s\n" "$gatekeeper_status"
