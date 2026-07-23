#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/dwb/dwb.xcodeproj"
SCHEME="${DWB_TEST_SCHEME:-dwbTests}"
CONFIGURATION="${DWB_TEST_CONFIGURATION:-Debug}"
DESTINATION="${DWB_TEST_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DWB_TEST_DERIVED_DATA_PATH:-$ROOT_DIR/.tmp/test-derivedData}"
PACKAGE_CACHE_PATH="${DWB_PACKAGE_CACHE_PATH:-$ROOT_DIR/.tmp/swiftpm-cache}"
CLANG_CACHE_PATH="${DWB_CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.tmp/clang-module-cache}"
SWIFT_CACHE_PATH="${DWB_SWIFT_MODULE_CACHE_PATH:-$ROOT_DIR/.tmp/swift-module-cache}"

mkdir -p "$DERIVED_DATA_PATH" "$PACKAGE_CACHE_PATH" "$CLANG_CACHE_PATH" "$SWIFT_CACHE_PATH"

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -packageCachePath "$PACKAGE_CACHE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
    SWIFT_MODULE_CACHE_PATH="$SWIFT_CACHE_PATH" \
    -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile \
    test
