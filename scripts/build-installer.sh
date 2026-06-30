#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/dwb xtreme.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXPECTED_VERSION="4.2.2"
PKG_NAME="dwb-xtreme-${EXPECTED_VERSION}.pkg"
PKG_PATH="$DIST_DIR/$PKG_NAME"
INSTALLER_INFO_PATH="$DIST_DIR/dwb-installer-build-info.txt"
INSTALL_LOCATION="/Applications"
release_mode="${DWB_INSTALLER_RELEASE:-0}"
notarize=0
allow_notarization_upload="${DWB_ALLOW_NOTARIZATION_UPLOAD:-0}"
check_release_inputs=0

usage() {
    cat <<'EOF'
Usage: scripts/build-installer.sh [options]

Options:
  --skip-app-build              Use existing dist/dwb xtreme.app
  --release                     Build a public installer candidate: Developer ID
                                sign the app, Developer ID Installer sign the
                                pkg, notarize, staple, and verify
  --notarize                    Submit the pkg for notarization; implies
                                --release and requires explicit upload approval
  --allow-notarization-upload   Permit xcrun notarytool submit for this run
  --check-release-inputs        Validate release signing/notary inputs and exit
                                without building, signing, notarizing, or upload
  --help                        Show this help text

Default mode builds a local installer package only. It does not notarize,
staple, upload, publish, tag, commit, install, or use credentials unless
release mode/signing variables are explicitly provided.

Release mode requires:
  DWB_SIGNING_IDENTITY          Developer ID Application identity for the app
  DWB_INSTALLER_SIGN_IDENTITY   Developer ID Installer identity for the pkg
  DWB_NOTARY_KEYCHAIN_PROFILE   Preferred notarytool keychain profile

Alternatively, notarization can use DWB_NOTARY_APPLE_ID, DWB_NOTARY_TEAM_ID,
and DWB_NOTARY_PASSWORD. Secret values are never printed.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-app-build)
            DWB_SKIP_APP_BUILD=1
            shift
            ;;
        --release)
            release_mode=1
            notarize=1
            shift
            ;;
        --notarize)
            release_mode=1
            notarize=1
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

find_identity_record() {
    local requested_identity="$1"
    security find-identity -v 2>/dev/null \
        | grep -F "$requested_identity" \
        | head -1 || true
}

validate_installer_identity() {
    local identity="$1"
    local record

    if [[ -z "$identity" ]]; then
        printf "ERROR: Release installer builds require DWB_INSTALLER_SIGN_IDENTITY with a Developer ID Installer identity.\n" >&2
        exit 1
    fi

    record="$(find_identity_record "$identity")"
    if [[ -z "$record" ]]; then
        printf "ERROR: Installer signing identity was not found in the local keychain search list.\n" >&2
        exit 1
    fi

    if [[ "$record" != *"Developer ID Installer:"* && "$identity" != Developer\ ID\ Installer:* ]]; then
        printf "ERROR: Release installer builds require a Developer ID Installer identity.\n" >&2
        exit 1
    fi
}

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

    if [[ "$allow_notarization_upload" != "1" ]]; then
        printf "ERROR: Notarization upload is disabled.\n" >&2
        printf "Set DWB_ALLOW_NOTARIZATION_UPLOAD=1 or pass --allow-notarization-upload for an authorized credentialed release pass.\n" >&2
        exit 1
    fi
}

validate_release_inputs() {
    if [[ -z "${DWB_SIGNING_IDENTITY:-}" ]]; then
        printf "ERROR: Release installer builds require DWB_SIGNING_IDENTITY with a Developer ID Application identity.\n" >&2
        exit 1
    fi

    zsh "$ROOT_DIR/scripts/sign-app.sh" \
        --identity "$DWB_SIGNING_IDENTITY" \
        --release \
        --check-release-inputs

    validate_installer_identity "${DWB_INSTALLER_SIGN_IDENTITY:-}"
    validate_notary_inputs
}

verify_release_signed_app() {
    local details

    codesign --verify --deep --strict --verbose=4 "$APP_PATH" 2>&1
    details="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
    printf "%s\n" "$details"

    if ! printf "%s\n" "$details" | grep -q "Authority=Developer ID Application:"; then
        printf "ERROR: Release installer app payload is not Developer ID Application signed.\n" >&2
        exit 1
    fi

    if ! printf "%s\n" "$details" | grep -q "Runtime Version"; then
        printf "ERROR: Release installer app payload does not show Hardened Runtime.\n" >&2
        exit 1
    fi
}

if [[ "$check_release_inputs" == "1" ]]; then
    validate_release_inputs
    printf "Installer release input check passed.\n"
    exit 0
fi

if [[ "$release_mode" == "1" || "$notarize" == "1" ]]; then
    validate_release_inputs
fi

# ── App build ──────────────────────────────────────────────────────────────
if [[ "${DWB_SKIP_APP_BUILD:-0}" != "1" ]]; then
    printf "Building app...\n"
    if [[ "$release_mode" == "1" ]]; then
        DWB_RELEASE_SIGN=1 bash "$ROOT_DIR/scripts/build-app.sh"
    else
        bash "$ROOT_DIR/scripts/build-app.sh"
    fi
fi

# ── App verification ───────────────────────────────────────────────────────
if [[ ! -d "$APP_PATH" ]]; then
    printf "ERROR: dist/dwb xtreme.app not found at %s\n" "$APP_PATH" >&2
    exit 1
fi

if [[ ! -f "$INFO_PLIST" ]]; then
    printf "ERROR: Info.plist not found at %s\n" "$INFO_PLIST" >&2
    exit 1
fi

app_version="$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || true)"
build_number="$(defaults read "$INFO_PLIST" CFBundleVersion 2>/dev/null || true)"

printf "App path:     %s\n" "$APP_PATH"
printf "App version:  %s\n" "$app_version"
printf "Build number: %s\n" "$build_number"

if [[ "$app_version" != "$EXPECTED_VERSION" ]]; then
    printf "ERROR: App version is '%s', expected '%s'. Rebuild with the correct version.\n" \
        "$app_version" "$EXPECTED_VERSION" >&2
    exit 1
fi

if [[ "$release_mode" == "1" ]]; then
    verify_release_signed_app
fi

# ── Stale pkg cleanup ──────────────────────────────────────────────────────
if [[ -f "$PKG_PATH" ]]; then
    printf "Removing stale installer: %s\n" "$PKG_PATH"
    rm -f "$PKG_PATH"
fi

# ── Signing setup ──────────────────────────────────────────────────────────
sign_identity="${DWB_INSTALLER_SIGN_IDENTITY:-}"
signing_status="unsigned (local only)"

# ── productbuild ───────────────────────────────────────────────────────────
printf "Building installer package: %s\n" "$PKG_PATH"

if [[ "$release_mode" == "1" ]]; then
    productbuild \
        --sign "$sign_identity" \
        --component "$APP_PATH" "$INSTALL_LOCATION" \
        "$PKG_PATH"
    signing_status="signed with Developer ID Installer identity"
elif [[ -n "$sign_identity" ]]; then
    productbuild \
        --sign "$sign_identity" \
        --component "$APP_PATH" "$INSTALL_LOCATION" \
        "$PKG_PATH"
    signing_status="signed with identity: $sign_identity"
else
    productbuild \
        --component "$APP_PATH" "$INSTALL_LOCATION" \
        "$PKG_PATH"
fi

if [[ ! -f "$PKG_PATH" ]]; then
    printf "ERROR: productbuild did not produce %s\n" "$PKG_PATH" >&2
    exit 1
fi

# ── Signature verification ─────────────────────────────────────────────────
sig_check="N/A (unsigned)"
if [[ -n "$sign_identity" ]]; then
    sig_check="$(pkgutil --check-signature "$PKG_PATH" 2>&1 || true)"
fi

# ── Notarization ───────────────────────────────────────────────────────────
notarization_status="skipped (not requested)"
notary_profile="${DWB_NOTARY_KEYCHAIN_PROFILE:-}"
notary_apple_id="${DWB_NOTARY_APPLE_ID:-}"
notary_team_id="${DWB_NOTARY_TEAM_ID:-}"
notary_password="${DWB_NOTARY_PASSWORD:-}"

if [[ "$notarize" == "1" ]]; then
    printf "Submitting installer package for notarization...\n"
    if [[ -n "$notary_profile" ]]; then
        xcrun notarytool submit "$PKG_PATH" \
            --keychain-profile "$notary_profile" \
            --wait
    elif [[ -n "$notary_apple_id" && -n "$notary_team_id" && -n "$notary_password" ]]; then
        xcrun notarytool submit "$PKG_PATH" \
            --apple-id "$notary_apple_id" \
            --team-id "$notary_team_id" \
            --password "$notary_password" \
            --wait
    else
        printf "ERROR: Notarization requested but credentials are missing.\n" >&2
        exit 1
    fi

    xcrun stapler staple "$PKG_PATH"
    xcrun stapler validate "$PKG_PATH"
    spctl -a -vv -t install "$PKG_PATH" 2>&1
    notarization_status="notarized and stapled"
fi

# ── SHA-256 ────────────────────────────────────────────────────────────────
pkg_sha256="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
pkg_size="$(ls -lh "$PKG_PATH" | awk '{print $5}')"
installer_date="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ── Build info ─────────────────────────────────────────────────────────────
{
    printf "installer_date_utc=%s\n" "$installer_date"
    printf "app_version=%s\n" "$app_version"
    printf "build_number=%s\n" "$build_number"
    printf "app_path=%s\n" "$APP_PATH"
    printf "install_location=%s\n" "$INSTALL_LOCATION"
    printf "pkg_path=%s\n" "$PKG_PATH"
    printf "pkg_size=%s\n" "$pkg_size"
    printf "pkg_sha256=%s\n" "$pkg_sha256"
    printf "signing_status=%s\n" "$signing_status"
    printf "notarization_status=%s\n" "$notarization_status"
} > "$INSTALLER_INFO_PATH"

# ── Summary ────────────────────────────────────────────────────────────────
printf "\n"
printf "Package path:       %s\n" "$PKG_PATH"
printf "Package size:       %s\n" "$pkg_size"
printf "SHA-256:            %s\n" "$pkg_sha256"
printf "Signing status:     %s\n" "$signing_status"
printf "Notarization:       %s\n" "$notarization_status"
printf "Install info:       %s\n" "$INSTALLER_INFO_PATH"
printf "\nInstaller build complete.\n"
