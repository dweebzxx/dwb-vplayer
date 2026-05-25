#!/usr/bin/env zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir:h}"
app_path="$root_dir/dist/dwb.app"
identity="${DWB_SIGNING_IDENTITY:-}"
adhoc=0
timestamp=0
verify_only=0

if [[ "${DWB_SIGN_TIMESTAMP:-0}" == "1" ]]; then
    timestamp=1
fi

usage() {
    cat <<'EOF'
Usage: scripts/sign-app.sh [options]

Options:
  --app <path>          App bundle to sign or verify. Default: dist/dwb.app
  --identity <name>     Signing identity name or hash. Default: DWB_SIGNING_IDENTITY
  --adhoc              Sign with ad-hoc identity "-"
  --timestamp          Request timestamp signing for non-ad-hoc identities
  --no-timestamp       Disable timestamp signing
  --verify-only        Do not sign; only run verification checks
  --help               Show this help text

If no identity is provided and --adhoc is not provided, ad-hoc signing is used.
This script does not create, import, export, print, or delete certificates,
private keys, keychains, credentials, or provisioning profiles.
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
        --identity)
            if [[ $# -lt 2 || -z "$2" ]]; then
                printf "ERROR: --identity requires a value.\n" >&2
                exit 2
            fi
            identity="$2"
            adhoc=0
            shift 2
            ;;
        --adhoc)
            identity="-"
            adhoc=1
            shift
            ;;
        --timestamp)
            timestamp=1
            shift
            ;;
        --no-timestamp)
            timestamp=0
            shift
            ;;
        --verify-only)
            verify_only=1
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

if [[ -z "$identity" ]]; then
    identity="-"
    adhoc=1
elif [[ "$identity" == "-" ]]; then
    adhoc=1
fi

if [[ "$adhoc" -eq 1 && "$timestamp" -eq 1 ]]; then
    printf "Timestamp requested, but ad-hoc signatures cannot be timestamped; using --timestamp=none.\n"
    timestamp=0
fi

app_path="${app_path:A}"
info_plist="$app_path/Contents/Info.plist"

if [[ ! -d "$app_path" ]]; then
    printf "ERROR: App bundle not found: %s\n" "$app_path" >&2
    exit 1
fi

if [[ ! -f "$info_plist" ]]; then
    printf "ERROR: Info.plist not found: %s\n" "$info_plist" >&2
    exit 1
fi

bundle_executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist" 2>/dev/null || true)"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist" 2>/dev/null || printf "unknown")"
build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info_plist" 2>/dev/null || printf "unknown")"
main_executable=""

if [[ -n "$bundle_executable" ]]; then
    main_executable="$app_path/Contents/MacOS/$bundle_executable"
fi

if [[ -z "$main_executable" || ! -x "$main_executable" ]]; then
    printf "ERROR: Bundle executable not found or not executable: %s\n" "${main_executable:-unknown}" >&2
    exit 1
fi

timestamp_label="none"
timestamp_args=(--timestamp=none)
if [[ "$timestamp" -eq 1 ]]; then
    timestamp_label="enabled"
    timestamp_args=(--timestamp)
fi

printf "App path:        %s\n" "$app_path"
if [[ "$adhoc" -eq 1 ]]; then
    printf "Identity:        ad-hoc (-)\n"
else
    printf "Identity:        %s\n" "$identity"
fi
printf "Timestamp mode:  %s\n" "$timestamp_label"
printf "App version:     %s\n" "$version"
printf "Bundle version:  %s\n" "$build"

is_macho_file() {
    local candidate="$1"
    [[ -f "$candidate" ]] || return 1
    /usr/bin/file -b "$candidate" 2>/dev/null | /usr/bin/grep -Eq 'Mach-O|ar archive|current ar archive'
}

sign_one() {
    local target="$1"
    printf "Signing:         %s\n" "$target"
    /usr/bin/codesign --force --sign "$identity" "${timestamp_args[@]}" "$target"
}

if [[ "$verify_only" -eq 0 ]]; then
    while IFS= read -r -d '' item; do
        sign_one "$item"
    done < <(/usr/bin/find "$app_path/Contents" -depth -type d \( \
        -name "*.framework" -o \
        -name "*.appex" -o \
        -name "*.xpc" -o \
        -name "*.bundle" -o \
        -name "*.app" \
    \) -print0)

    while IFS= read -r -d '' item; do
        if [[ "$item" == "$main_executable" ]]; then
            continue
        fi
        if is_macho_file "$item"; then
            case "$item" in
                */*.framework/*|*/*.appex/*|*/*.xpc/*|*/*.bundle/*|*/*.app/*)
                    ;;
                *)
                    sign_one "$item"
                    ;;
            esac
        fi
    done < <(/usr/bin/find "$app_path/Contents" -type f -print0)

    sign_one "$app_path"
else
    printf "Signing:         skipped (--verify-only)\n"
fi

printf "\nCodesign verification:\n"
if /usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path" 2>&1; then
    codesign_status="passed"
else
    codesign_status="failed"
fi

printf "\nCodesign details:\n"
/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 || true

printf "\nspctl assessment:\n"
if /usr/sbin/spctl -a -vv "$app_path" 2>&1; then
    spctl_status="accepted"
else
    spctl_status="rejected or unavailable"
fi

printf "\nSigning verification outcome: %s\n" "$codesign_status"
printf "spctl outcome:                %s\n" "$spctl_status"

if [[ "$codesign_status" != "passed" ]]; then
    exit 1
fi
