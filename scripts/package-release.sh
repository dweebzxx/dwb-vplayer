#!/usr/bin/env zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir:h}"

app_path="$root_dir/dist/dwb player.app"
release_root="$root_dir/dist/release"
output_dir=""
version="4.1.2"
build="412"
skip_build=0

usage() {
    cat <<'EOF'
Usage: scripts/package-release.sh [options]

Options:
  --app <path>          App bundle to package. Default: dist/dwb player.app
  --output-dir <path>   Release artifact directory. Default: dist/release/dwb-player-<version>
  --version <version>   Expected app/release version. Default: 4.1.2
  --build <build>       Expected bundle build number. Default: 412
  --skip-build          Package the existing app after verification
  --help                Show this help text

By default this script runs ./scripts/build-app.sh before packaging.
It creates a local ZIP, SHA-256 file, manifest JSON, and release notes draft.
It does not create a GitHub release, upload assets, notarize, staple, tag, or commit.
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

if [[ "$skip_build" -eq 0 ]]; then
    printf "Building app before packaging...\n"
    "$root_dir/scripts/build-app.sh"
else
    printf "Skipping build; packaging existing app.\n"
fi

printf "Verifying source app: %s\n" "$app_path"
verify_app_version "$app_path"
"$root_dir/scripts/sign-app.sh" --app "$app_path" --verify-only

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

cat > "$notes_path" <<EOF
# dwb video player v${version}

## Overview

This is a local draft release note for the dwb video player ${version} macOS ZIP artifact. It has not been uploaded or published.

## Highlights

- Native AppKit local media playback for macOS 13 and newer.
- VLCKit-backed video playback with support for common local video formats: mp4, m4v, mov, avi, flv, f4v, wmv, asf, mkv, ts, mts, m2ts, m2t, mpg, 3gp, 3g2, vob, ogv, and ogm.
- Still-image and animated GIF playback for jpg/jpeg, jfif, png, gif, tiff/tif, bmp, heic, heif, and webp.
- Queue Page, quick queueing, shuffle/endless shuffle, repeat one, and multi-window playback.
- Four Window Grid layout, bottom rail controls, Settings, and local file workflow controls.
- One-click x_ prefix rename and custom-prefix rename work for videos, images, and GIFs.

## Feature Groups

- Playback: local video playback, image/GIF viewing, seek controls, volume, fullscreen, scaling, repeat, and shuffle modes.
- Queue: sortable Queue Page, multi-select removal, drag ordering, total duration, Reveal in Finder, x_ prefix rename, and custom-prefix rename.
- Windows: independent player windows, per-window playback state, opacity, on-top mode, titlebar behavior, and four-window arrangement.
- Settings: playback, controls, queue/file behavior, titlebar, rail, opacity, and developer/debug options.
- Unsupported: this release does not claim .ogg support.

## Signing And Notarization Status

- This artifact is ad-hoc signed.
- It is not Developer ID signed.
- It is not notarized.
- It is not stapled.
- Gatekeeper readiness is not claimed.

## Install And Open Note

Extract \`${zip_name}\` to produce \`dwb player.app\`. Because this is an ad-hoc signed, non-notarized local build, macOS Gatekeeper can reject it on first open. Use only for local verification unless a future pass produces a Developer ID signed and notarized artifact.

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
- Gatekeeper acceptance is not expected for this ad-hoc, non-notarized artifact.
EOF

cat > "$manifest_path" <<EOF
{
  "app_name": $(json_string "dwb"),
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
    "x_ prefix rename for videos, images, and GIFs",
    "custom-prefix rename for videos, images, and GIFs"
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
