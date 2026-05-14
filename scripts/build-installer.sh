#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/dwb.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXPECTED_VERSION="4.0.0"
PKG_NAME="dwb-${EXPECTED_VERSION}.pkg"
PKG_PATH="$DIST_DIR/$PKG_NAME"
INSTALLER_INFO_PATH="$DIST_DIR/dwb-installer-build-info.txt"
INSTALL_LOCATION="/Applications"

# ── App build ──────────────────────────────────────────────────────────────
if [[ "${DWB_SKIP_APP_BUILD:-0}" != "1" ]]; then
    printf "Building app...\n"
    bash "$ROOT_DIR/scripts/build-app.sh"
fi

# ── App verification ───────────────────────────────────────────────────────
if [[ ! -d "$APP_PATH" ]]; then
    printf "ERROR: dist/dwb.app not found at %s\n" "$APP_PATH" >&2
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

if [[ -n "$sign_identity" ]]; then
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
notarization_status="skipped (no credentials provided)"
notary_profile="${DWB_NOTARY_KEYCHAIN_PROFILE:-}"
notary_apple_id="${DWB_NOTARY_APPLE_ID:-}"
notary_team_id="${DWB_NOTARY_TEAM_ID:-}"
notary_password="${DWB_NOTARY_PASSWORD:-}"

if [[ -n "$notary_profile" ]]; then
    printf "Submitting for notarization (keychain profile: %s)...\n" "$notary_profile"
    xcrun notarytool submit "$PKG_PATH" \
        --keychain-profile "$notary_profile" \
        --wait
    xcrun stapler staple "$PKG_PATH"
    notarization_status="notarized and stapled (keychain profile: $notary_profile)"
elif [[ -n "$notary_apple_id" && -n "$notary_team_id" && -n "$notary_password" ]]; then
    printf "Submitting for notarization (Apple ID: %s)...\n" "$notary_apple_id"
    xcrun notarytool submit "$PKG_PATH" \
        --apple-id "$notary_apple_id" \
        --team-id "$notary_team_id" \
        --password "$notary_password" \
        --wait
    xcrun stapler staple "$PKG_PATH"
    notarization_status="notarized and stapled (Apple ID: $notary_apple_id)"
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
