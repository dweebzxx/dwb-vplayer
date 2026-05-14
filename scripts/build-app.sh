#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/dwb/dwb.xcodeproj"
SCHEME="${DWB_SCHEME:-dwb}"
CONFIGURATION="${DWB_CONFIGURATION:-Release}"
DESTINATION="${DWB_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DWB_DERIVED_DATA_PATH:-$ROOT_DIR/.tmp/derivedData}"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP_PATH="$DIST_DIR/dwb.app"
BUILD_INFO_PATH="$DIST_DIR/dwb-app-build-info.txt"
TMP_ROOT="${TMPDIR:-/tmp}/dwb-app-build"
BUILD_SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/dwb-build-settings.XXXXXX")"
CLANG_CACHE_PATH="${DWB_CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.tmp/clang-module-cache}"
SWIFT_CACHE_PATH="${DWB_SWIFT_MODULE_CACHE_PATH:-$ROOT_DIR/.tmp/swift-module-cache}"
SWIFTPM_CACHE_PATH="${DWB_PACKAGE_CACHE_PATH:-$ROOT_DIR/.tmp/swiftpm-cache}"

cleanup() {
    rm -f "$BUILD_SETTINGS_FILE"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR" "$CLANG_CACHE_PATH" "$SWIFT_CACHE_PATH" "$SWIFTPM_CACHE_PATH"

build_date="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
git_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf "unavailable")"
xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || printf "unavailable")"
build_mode="standard"
effective_project_path="$PROJECT_PATH"

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
        printf "built_app_path=%s\n" "$built_app_path"
        printf "dist_app_path=%s\n" "$DIST_APP_PATH"
        printf "git_commit=%s\n" "$git_commit"
        printf "xcode_version=%s\n" "$xcode_version"
        printf "build_succeeded=%s\n" "$status"
    } > "$BUILD_INFO_PATH"
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

build_standard() {
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

find_cached_vlckit_products() {
    if [[ -n "${DWB_VLCKIT_PRODUCTS_DIR:-}" &&
          -f "$DWB_VLCKIT_PRODUCTS_DIR/VLCKitSPM.o" &&
          -d "$DWB_VLCKIT_PRODUCTS_DIR/VLCKitSPM.swiftmodule" &&
          -d "$DWB_VLCKIT_PRODUCTS_DIR/VLCKit.framework" ]]; then
        printf "%s\n" "$DWB_VLCKIT_PRODUCTS_DIR"
        return 0
    fi

    local candidate
    candidate="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*/Build/Products/$CONFIGURATION/VLCKitSPM.o" \
        -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        candidate="$(dirname "$candidate")"
        if [[ -d "$candidate/VLCKitSPM.swiftmodule" && -d "$candidate/VLCKit.framework" ]]; then
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
    build_mode="cached-vlckit-products"
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
    printf "Standard build failed; attempting cached VLCKit build fallback.\n" >&2
    if cached_products="$(find_cached_vlckit_products)"; then
        if ! build_no_swiftpm_from_cache "$cached_products"; then
            write_build_info "NO"
            exit 1
        fi
    else
        write_build_info "NO"
        printf "No cached VLCKit products found. Set DWB_VLCKIT_PRODUCTS_DIR and retry.\n" >&2
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

if [[ "$build_mode" == "cached-vlckit-products" ]]; then
    mkdir -p "$built_app_path/Contents/Frameworks"
    ditto "$cached_products/VLCKit.framework" "$built_app_path/Contents/Frameworks/VLCKit.framework"
fi

copy_app_to_dist "$built_app_path"
