#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/dwb/dwb.xcodeproj"
SCHEME="${DWB_SCHEME:-dwb}"
CONFIGURATION="${DWB_CONFIGURATION:-Release}"
DESTINATION="${DWB_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DWB_DERIVED_DATA_PATH:-$ROOT_DIR/.tmp/derivedData}"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP_PATH="$DIST_DIR/dwb player.app"
BUILD_INFO_PATH="$DIST_DIR/dwb-player-app-build-info.txt"
TMP_ROOT="${TMPDIR:-/tmp}/dwb-player-app-build"
BUILD_SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/dwb-player-build-settings.XXXXXX")"
CLANG_CACHE_PATH="${DWB_CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.tmp/clang-module-cache}"
SWIFT_CACHE_PATH="${DWB_SWIFT_MODULE_CACHE_PATH:-$ROOT_DIR/.tmp/swift-module-cache}"
SWIFTPM_CACHE_PATH="${DWB_PACKAGE_CACHE_PATH:-$ROOT_DIR/.tmp/swiftpm-cache}"
ALLOW_DEV_CACHED_VLCKIT_FALLBACK="${DWB_ALLOW_DEV_CACHED_VLCKIT_FALLBACK:-0}"
VLCKIT_PACKAGE_IDENTITY="vlckit-spm"
VLCKIT_PACKAGE_URL="https://github.com/tylerjonesio/vlckit-spm"
VLCKIT_PACKAGE_VERSION="3.6.0"
VLCKIT_PACKAGE_REVISION="e932bbd488872fdb74f6654d28c2f291eae03daf"
VLCKIT_BINARY_URL="https://github.com/tylerjonesio/vlckit-spm/releases/download/3.6.0/VLCKit-all.xcframework.zip"
VLCKIT_BINARY_CHECKSUM="5da4747e001900bbb4153f58db2be4695096c9c2350aea00376ad67b39c053f6"
EXPECTED_ARCH="${DWB_EXPECTED_ARCH:-$(uname -m)}"

cleanup() {
    rm -f "$BUILD_SETTINGS_FILE"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR" "$CLANG_CACHE_PATH" "$SWIFT_CACHE_PATH" "$SWIFTPM_CACHE_PATH"
rm -rf "$DIST_APP_PATH"
rm -f "$BUILD_INFO_PATH"

build_date="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
git_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf "unavailable")"
xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || printf "unavailable")"
swift_version="$(swift --version 2>/dev/null | head -1 || printf "unavailable")"
macos_sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || printf "unavailable")"
build_mode="standard-swiftpm"
effective_project_path="$PROJECT_PATH"
vlckit_provenance_status="standard SwiftPM pinned by Package.resolved"
vlckit_artifact_path="managed by SwiftPM/Xcode"
vlckit_cached_products_dir="not used"

write_build_info() {
    local status="$1"
    local built_app_path="${2:-unavailable}"
    {
        printf "build_date_utc=%s\n" "$build_date"
        printf "scheme=%s\n" "$SCHEME"
        printf "configuration=%s\n" "$CONFIGURATION"
        printf "project_path=%s\n" "$PROJECT_PATH"
        printf "effective_project_path=%s\n" "$effective_project_path"
        printf "destination=%s\n" "$DESTINATION"
        printf "derived_data_path=%s\n" "$DERIVED_DATA_PATH"
        printf "build_mode=%s\n" "$build_mode"
        printf "vlckit_package_identity=%s\n" "$VLCKIT_PACKAGE_IDENTITY"
        printf "vlckit_package_url=%s\n" "$VLCKIT_PACKAGE_URL"
        printf "vlckit_package_version=%s\n" "$VLCKIT_PACKAGE_VERSION"
        printf "vlckit_package_revision=%s\n" "$VLCKIT_PACKAGE_REVISION"
        printf "vlckit_binary_url=%s\n" "$VLCKIT_BINARY_URL"
        printf "vlckit_binary_checksum=%s\n" "$VLCKIT_BINARY_CHECKSUM"
        printf "vlckit_artifact_path=%s\n" "$vlckit_artifact_path"
        printf "vlckit_cached_products_dir=%s\n" "$vlckit_cached_products_dir"
        printf "vlckit_provenance_status=%s\n" "$vlckit_provenance_status"
        printf "dev_cached_vlckit_fallback_allowed=%s\n" "$ALLOW_DEV_CACHED_VLCKIT_FALLBACK"
        printf "expected_arch=%s\n" "$EXPECTED_ARCH"
        printf "built_app_path=%s\n" "$built_app_path"
        printf "dist_app_path=%s\n" "$DIST_APP_PATH"
        printf "git_commit=%s\n" "$git_commit"
        printf "xcode_version=%s\n" "$xcode_version"
        printf "swift_version=%s\n" "$swift_version"
        printf "macos_sdk_version=%s\n" "$macos_sdk_version"
        printf "build_succeeded=%s\n" "$status"
    } > "$BUILD_INFO_PATH"
}

detect_stale_vlckit_paths() {
    local files=()
    local workspace_state="$DERIVED_DATA_PATH/SourcePackages/workspace-state.json"
    local pif_cache="$DERIVED_DATA_PATH/Build/Intermediates.noindex/XCBuildData/PIFCache"
    [[ -f "$workspace_state" ]] && files+=("$workspace_state")
    if [[ -d "$pif_cache" ]]; then
        local file
        while IFS= read -r file; do
            files+=("$file")
        done < <(find "$pif_cache" -type f \( -name '*-json' -o -name '*.json' \) -print 2>/dev/null)
    fi
    [[ ${#files[@]} -gt 0 ]] || return 0

    LC_ALL=C grep -IhoE '/[^"[:space:]]*(VLCKit-all\.xcframework|SourcePackages/(artifacts|checkouts)/vlckit-spm|Build/Products/Release/VLCKit(SPM)?(\.framework|\.o|\.swiftmodule)?)' "${files[@]}" 2>/dev/null \
        | LC_ALL=C sort -u \
        | while IFS= read -r path; do
            case "$path" in
                //*) ;;
                "$ROOT_DIR"/*) ;;
                "$DERIVED_DATA_PATH"/*) ;;
                *) printf "%s\n" "$path" ;;
            esac
          done
}

clean_stale_vlckit_build_state_if_needed() {
    local stale_paths
    stale_paths="$(detect_stale_vlckit_paths || true)"
    [[ -n "$stale_paths" ]] || return 0

    printf "Detected stale VLCKit SwiftPM artifact paths in project-local build state:\n" >&2
    printf "%s\n" "$stale_paths" >&2
    printf "Cleaning repo-local generated Xcode state so SwiftPM can regenerate local artifact paths.\n" >&2

    local workspace_state="$DERIVED_DATA_PATH/SourcePackages/workspace-state.json"
    local build_root="$DERIVED_DATA_PATH/Build"

    [[ -f "$workspace_state" ]] && rm -f "$workspace_state" && printf "Removed %s\n" "$workspace_state" >&2
    [[ -d "$build_root" ]] && rm -rf "$build_root" && printf "Removed %s\n" "$build_root" >&2
}

print_build_path_diagnostics() {
    printf "Build path diagnostics:\n" >&2
    printf "  root: %s\n" "$ROOT_DIR" >&2
    printf "  derived data: %s\n" "$DERIVED_DATA_PATH" >&2
    printf "  package cache: %s\n" "$SWIFTPM_CACHE_PATH" >&2
    printf "  clang module cache: %s\n" "$CLANG_CACHE_PATH" >&2
    printf "  swift module cache: %s\n" "$SWIFT_CACHE_PATH" >&2
    printf "  dev cached VLCKit fallback allowed: %s\n" "$ALLOW_DEV_CACHED_VLCKIT_FALLBACK" >&2
    printf "  expected arch: %s\n" "$EXPECTED_ARCH" >&2
    printf "  Swift: %s\n" "$swift_version" >&2
    printf "  macOS SDK: %s\n" "$macos_sdk_version" >&2
    printf "  searched cached VLCKit product roots:\n" >&2
    printf "    %s\n" "$DERIVED_DATA_PATH/Build/Products" >&2
    printf "    %s\n" "$ROOT_DIR/.tmp" >&2
    if [[ -n "${DWB_VLCKIT_PRODUCTS_DIR:-}" ]]; then
        printf "    %s (DWB_VLCKIT_PRODUCTS_DIR)\n" "$DWB_VLCKIT_PRODUCTS_DIR" >&2
    fi

    local stale_paths
    stale_paths="$(detect_stale_vlckit_paths || true)"
    if [[ -n "$stale_paths" ]]; then
        printf "  stale absolute VLCKit artifact paths still present:\n" >&2
        printf "%s\n" "$stale_paths" | sed 's/^/    /' >&2
    else
        printf "  stale absolute VLCKit artifact paths: none detected\n" >&2
    fi
}

show_build_settings() {
    xcodebuild \
        -project "$effective_project_path" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        -showBuildSettings > "$BUILD_SETTINGS_FILE"
}

copy_app_to_dist() {
    local built_app_path="$1"
    rm -rf "$DIST_APP_PATH"
    ditto "$built_app_path" "$DIST_APP_PATH"
    write_build_info "YES" "$built_app_path"
    printf "Built app copied to %s\n" "$DIST_APP_PATH"
    printf "Build info written to %s\n" "$BUILD_INFO_PATH"
}

sign_dist_app() {
    if [[ "${DWB_SKIP_SIGN:-0}" == "1" ]]; then
        printf "App signing skipped because DWB_SKIP_SIGN=1\n"
        return 0
    fi

    local sign_args=(--app "$DIST_APP_PATH")
    if [[ "${DWB_RELEASE_SIGN:-0}" == "1" ]]; then
        if [[ -z "${DWB_SIGNING_IDENTITY:-}" ]]; then
            printf "ERROR: DWB_RELEASE_SIGN=1 requires DWB_SIGNING_IDENTITY with a Developer ID Application identity.\n" >&2
            exit 1
        fi
        sign_args+=(--identity "$DWB_SIGNING_IDENTITY" --release)
    elif [[ -n "${DWB_SIGNING_IDENTITY:-}" ]]; then
        sign_args+=(--identity "$DWB_SIGNING_IDENTITY")
        if [[ "${DWB_SIGNING_IDENTITY:-}" != "-" && "${DWB_SIGN_TIMESTAMP:-0}" == "1" ]]; then
            sign_args+=(--timestamp)
        else
            sign_args+=(--no-timestamp)
        fi
    else
        sign_args+=(--adhoc --no-timestamp)
    fi

    zsh "$ROOT_DIR/scripts/sign-app.sh" "${sign_args[@]}"
}

build_standard() {
    clean_stale_vlckit_build_state_if_needed
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -packageCachePath "$SWIFTPM_CACHE_PATH" \
        -onlyUsePackageVersionsFromResolvedFile \
        -resolvePackageDependencies

    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -packageCachePath "$SWIFTPM_CACHE_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
        SWIFT_MODULE_CACHE_PATH="$SWIFT_CACHE_PATH" \
        -skipPackageUpdates \
        -onlyUsePackageVersionsFromResolvedFile \
        build
}

is_repo_local_path() {
    local candidate="$1"
    case "$candidate" in
        "$ROOT_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

swift_version_number() {
    sed -nE 's/.*Apple Swift version ([^ ]+).*/\1/p' | head -1
}

validate_cached_vlckit_products() {
    local candidate="$1"
    local module_file="$candidate/VLCKitSPM.swiftmodule/${EXPECTED_ARCH}-apple-macos.swiftmodule"
    local framework_binary="$candidate/VLCKit.framework/VLCKit"
    local current_swift module_swift stale_module_paths

    if ! is_repo_local_path "$candidate"; then
        printf "Rejected cached VLCKit products outside this repository: %s\n" "$candidate" >&2
        return 1
    fi

    if [[ ! -f "$candidate/VLCKitSPM.o" ||
          ! -d "$candidate/VLCKitSPM.swiftmodule" ||
          ! -f "$module_file" ||
          ! -d "$candidate/VLCKit.framework" ||
          ! -f "$framework_binary" ]]; then
        printf "Rejected cached VLCKit products with missing framework/module pieces: %s\n" "$candidate" >&2
        return 1
    fi

    if ! file "$candidate/VLCKitSPM.o" 2>/dev/null | grep -q "$EXPECTED_ARCH"; then
        printf "Rejected cached VLCKit object for incompatible architecture: %s\n" "$candidate/VLCKitSPM.o" >&2
        return 1
    fi

    if ! lipo -info "$framework_binary" 2>/dev/null | grep -q "$EXPECTED_ARCH"; then
        printf "Rejected cached VLCKit framework for incompatible architecture: %s\n" "$framework_binary" >&2
        return 1
    fi

    current_swift="$(printf "%s\n" "$swift_version" | swift_version_number)"
    module_swift="$(strings "$module_file" 2>/dev/null | swift_version_number)"
    if [[ -n "$current_swift" && -n "$module_swift" && "$current_swift" != "$module_swift" ]]; then
        printf "Rejected cached VLCKit module built with Swift %s; current Swift is %s.\n" "$module_swift" "$current_swift" >&2
        return 1
    fi

    stale_module_paths="$(strings "$module_file" 2>/dev/null \
        | LC_ALL=C grep -E '/[^[:space:]]*/dwb-[^[:space:]]*/.*\.tmp/derivedData' \
        | LC_ALL=C grep -vF "$ROOT_DIR" \
        | head -5 || true)"
    if [[ -n "$stale_module_paths" ]]; then
        printf "Rejected cached VLCKit module containing stale project paths:\n" >&2
        printf "%s\n" "$stale_module_paths" >&2
        return 1
    fi

    return 0
}

find_cached_vlckit_products() {
    if [[ -n "${DWB_VLCKIT_PRODUCTS_DIR:-}" ]]; then
        if validate_cached_vlckit_products "$DWB_VLCKIT_PRODUCTS_DIR"; then
            printf "%s\n" "$DWB_VLCKIT_PRODUCTS_DIR"
            return 0
        fi
        return 1
    fi

    local candidate
    candidate="$(find "$DERIVED_DATA_PATH/Build/Products" "$ROOT_DIR/.tmp" \
        -path "*/Build/Products/$CONFIGURATION/VLCKitSPM.o" \
        -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        candidate="$(dirname "$candidate")"
        if validate_cached_vlckit_products "$candidate"; then
            printf "Using validated local-development cached VLCKit products discovered at %s\n" "$candidate" >&2
            printf "%s\n" "$candidate"
            return 0
        fi
    fi
    return 1
}

prepare_no_swiftpm_project() {
    local temp_project_root="$1"
    rm -rf "$temp_project_root"
    mkdir -p "$temp_project_root/dwb"
    (cd "$ROOT_DIR/dwb" && tar --exclude=".DS_Store" -cf - .) | (cd "$temp_project_root/dwb" && tar -xf -)

    perl -0pi -e '
        s/\n\t\tF1DCB071ED1D9B9BD16097B5 \/\* VLCKitSPM in Frameworks \*\/ = \{isa = PBXBuildFile; productRef = A18894B0104EF9D2A3883F18 \/\* VLCKitSPM \*\/; \};\n/\n/;
        s/\n\t\t\t\tF1DCB071ED1D9B9BD16097B5 \/\* VLCKitSPM in Frameworks \*\/,\n//;
        s/\n\t\t\tpackageProductDependencies = \(\n\t\t\t\tA18894B0104EF9D2A3883F18 \/\* VLCKitSPM \*\/,\n\t\t\t\);/\n\t\t\tpackageProductDependencies = (\n\t\t\t);/;
        s/\n\t\t\tpackageReferences = \(\n\t\t\t\t1959D4A16EC32F26B0A89E0E \/\* XCRemoteSwiftPackageReference "vlckit-spm" \*\/,\n\t\t\t\);/\n\t\t\tpackageReferences = (\n\t\t\t);/;
        s/\n\/\* Begin XCRemoteSwiftPackageReference section \*\/.*?\/\* End XCRemoteSwiftPackageReference section \*\/\n//s;
        s/\n\/\* Begin XCSwiftPackageProductDependency section \*\/.*?\/\* End XCSwiftPackageProductDependency section \*\/\n//s;
    ' "$temp_project_root/dwb/dwb.xcodeproj/project.pbxproj"
}

build_no_swiftpm_from_cache() {
    local vlckit_products_dir="$1"
    local temp_project_root="$TMP_ROOT/project"
    build_mode="cached-vlckit-products-dev-only"
    vlckit_provenance_status="local-development cached products validated for path, architecture, and Swift compiler; not release provenance"
    vlckit_artifact_path="$vlckit_products_dir/VLCKit.framework"
    vlckit_cached_products_dir="$vlckit_products_dir"
    DERIVED_DATA_PATH="${DWB_FALLBACK_DERIVED_DATA_PATH:-$TMP_ROOT/DerivedData}"
    prepare_no_swiftpm_project "$temp_project_root"
    effective_project_path="$temp_project_root/dwb/dwb.xcodeproj"

    xcodebuild \
        -project "$effective_project_path" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        FRAMEWORK_SEARCH_PATHS="$vlckit_products_dir \$(inherited)" \
        SWIFT_INCLUDE_PATHS="$vlckit_products_dir" \
        OTHER_LDFLAGS="$vlckit_products_dir/VLCKitSPM.o -framework VLCKit" \
        CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
        SWIFT_MODULE_CACHE_PATH="$SWIFT_CACHE_PATH" \
        build
}

if ! build_standard; then
    printf "Standard SwiftPM build failed.\n" >&2
    print_build_path_diagnostics
    if [[ "$ALLOW_DEV_CACHED_VLCKIT_FALLBACK" != "1" ]]; then
        build_mode="standard-swiftpm-failed"
        vlckit_provenance_status="standard SwiftPM build failed; cached VLCKit fallback disabled by default for provenance safety"
        write_build_info "NO"
        printf "Cached VLCKit fallback is disabled by default because cached products are local-development-only and not release provenance.\n" >&2
        printf "For local development only, set DWB_ALLOW_DEV_CACHED_VLCKIT_FALLBACK=1; stale or incompatible caches will still be rejected.\n" >&2
        exit 1
    elif cached_products="$(find_cached_vlckit_products)"; then
        build_no_swiftpm_from_cache "$cached_products" || {
            write_build_info "NO"
            print_build_path_diagnostics
            exit 1
        }
    else
        write_build_info "NO"
        printf "No valid cached VLCKit products found in project-local generated build state.\n" >&2
        print_build_path_diagnostics
        exit 1
    fi
fi

if ! show_build_settings; then
    write_build_info "NO"
    exit 1
fi

built_products_dir="$(awk -F'= ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }' "$BUILD_SETTINGS_FILE")"
full_product_name="$(awk -F'= ' '/^[[:space:]]*FULL_PRODUCT_NAME = / { print $2; exit }' "$BUILD_SETTINGS_FILE")"

if [[ -z "$built_products_dir" || -z "$full_product_name" ]]; then
    write_build_info "NO"
    printf "Unable to locate built app from xcodebuild -showBuildSettings\n" >&2
    exit 1
fi

built_app_path="$built_products_dir/$full_product_name"
if [[ ! -d "$built_app_path" ]]; then
    write_build_info "NO" "$built_app_path"
    printf "Built app was not found at %s\n" "$built_app_path" >&2
    exit 1
fi

if [[ "$build_mode" == "cached-vlckit-products-dev-only" ]]; then
    mkdir -p "$built_app_path/Contents/Frameworks"
    ditto "$cached_products/VLCKit.framework" "$built_app_path/Contents/Frameworks/VLCKit.framework"
fi

copy_app_to_dist "$built_app_path"
sign_dist_app
