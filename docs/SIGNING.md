# Signing dwb xtreme

This document describes the local macOS signing workflow for `dwb xtreme.app`.

This workflow does not notarize the app, create a GitHub release, upload artifacts, or make the app Gatekeeper-ready unless Developer ID signing, Hardened Runtime, notarization, stapling, and Gatekeeper verification are explicitly requested and completed.

P83 defines the release hardening posture only. It does not publish a binary, use Apple credentials, import certificates, create keychain profiles, notarize, staple, tag, commit, push, or create a GitHub release.

## Release posture summary

The intended distribution posture is:

- Source/local build: `./scripts/build-app.sh` remains credential-free and may produce an unsigned or ad-hoc signed app.
- Ad-hoc local app: the default build signs `dist/dwb xtreme.app` with identity `-` so `codesign --verify --deep --strict` can pass for local hygiene.
- Developer ID public binary: public release signing must use a Developer ID Application identity with Hardened Runtime and timestamping.
- Notarized/stapled public binary: notarization must be requested explicitly, performed against the release artifact, stapled where Apple supports stapling, and verified before publication.
- Gatekeeper verification: `spctl -a -vv` must be recorded for the exact app/package that will be distributed, or for the app extracted from the exact ZIP.
- Installer/package release: a public `.pkg` requires a Developer ID Installer identity, notarization, stapling, and `spctl -a -vv -t install` verification.
- App Sandbox: not adopted in P83. It remains an explicit future design decision.

Public binary release must not be described as ready until the exact artifact is Developer ID signed, notarized, stapled where applicable, and Gatekeeper verified.

## Current local build mode

The canonical build command is:

```sh
./scripts/build-app.sh
```

The default build path uses Xcode/SwiftPM resolution for the pinned VLCKit dependency in `Package.resolved`. Cached VLCKit products are local-development-only, disabled by default, and are not a substitute for release dependency provenance.

By default, the build script produces `dist/dwb xtreme.app` and then runs:

```sh
scripts/sign-app.sh --app "dist/dwb xtreme.app" --adhoc --no-timestamp
```

That fixes the previous malformed linker/ad-hoc posture by applying a real bundle signature with sealed resources and a bound `Info.plist`. It is still only ad-hoc signed, not Developer ID signed, not notarized, and not stapled.

To build without signing:

```sh
DWB_SKIP_SIGN=1 ./scripts/build-app.sh
```

## Signing script

Run the signing script directly when you need to sign or verify an existing app bundle:

```sh
scripts/sign-app.sh --app "dist/dwb xtreme.app" --adhoc
scripts/sign-app.sh --app "dist/dwb xtreme.app" --verify-only
```

Options:

```text
--app <path>          App bundle to sign or verify. Default: dist/dwb xtreme.app
--identity <name>     Signing identity name or hash. Default: DWB_SIGNING_IDENTITY
--adhoc              Sign with ad-hoc identity "-"
--timestamp          Request timestamp signing for non-ad-hoc identities
--no-timestamp       Disable timestamp signing
--hardened-runtime   Sign with codesign --options runtime
--no-hardened-runtime
                     Disable codesign --options runtime
--release            Require Developer ID Application signing, Hardened Runtime,
                     and timestamping
--check-release-inputs
                     Validate release signing inputs and exit without signing
--verify-only        Do not sign; only run verification checks
--help               Show help text
```

If no identity is provided and `--adhoc` is not provided, the script signs ad-hoc with identity `-`.

The script does not create, export, import, print, or delete certificates, private keys, keychains, credentials, or provisioning profiles. It may print the signing identity name that was provided or made visible by local tools.

## Ad-hoc signing

Ad-hoc signing is the default local workflow:

```sh
scripts/sign-app.sh --app "dist/dwb xtreme.app" --adhoc
```

Ad-hoc signing can make `codesign --verify --deep --strict` pass for local build hygiene. It does not identify a developer to macOS Gatekeeper and does not make the app suitable as a public release download.

Expected verification shape for ad-hoc builds:

```sh
codesign --verify --deep --strict --verbose=4 "dist/dwb xtreme.app"
codesign -dv --verbose=4 "dist/dwb xtreme.app"
spctl -a -vv "dist/dwb xtreme.app"
```

`codesign` should pass. `spctl` can reject the app because ad-hoc signing is not Developer ID signing and the local workflow does not notarize.

## Self-signed or local certificate signing

If you have a local code-signing certificate already available in your keychain, use it explicitly:

```sh
scripts/sign-app.sh --app "dist/dwb xtreme.app" --identity "Your Local Signing Identity" --no-timestamp
```

Or for build integration:

```sh
DWB_SIGNING_IDENTITY="Your Local Signing Identity" ./scripts/build-app.sh
```

Self-signed or local certificate signing is useful for local testing only. It is not equivalent to Developer ID signing and should not be described as Gatekeeper-ready unless `spctl` accepts the exact artifact for the intended distribution path and the trust model is understood.

## Developer ID signing

Developer ID distribution requires an installed Developer ID Application identity:

```sh
security find-identity -v -p codesigning
DWB_SIGNING_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" DWB_RELEASE_SIGN=1 ./scripts/build-app.sh
```

Release signing mode requires the identity to resolve to a Developer ID Application certificate. It enables Hardened Runtime with `codesign --options runtime` and timestamping. This project does not provision Developer ID credentials and does not select a Developer ID identity automatically.

Check release signing inputs without signing or uploading:

```sh
scripts/sign-app.sh --identity "Developer ID Application: Example, Inc. (TEAMID)" --release --check-release-inputs
```

## Notarization and stapling

Developer ID signing alone is not notarization. A public macOS download normally needs:

1. Developer ID Application signing.
2. Submission to Apple notarization.
3. Successful notarization result.
4. Stapling where applicable.
5. Verification of the final distributed artifact.

The local build workflow intentionally does not run `xcrun notarytool submit`, does not use Apple ID credentials or keychain profiles, and does not run `xcrun stapler staple`.

The release scripts require explicit notarization intent plus upload permission before `notarytool submit` can run. Supplying notary credential environment variables alone is not enough.

Preferred credential strategy:

```sh
DWB_NOTARY_KEYCHAIN_PROFILE="profile-name"
```

Alternative documented strategy:

```sh
DWB_NOTARY_APPLE_ID="apple-id@example.com"
DWB_NOTARY_TEAM_ID="TEAMID"
DWB_NOTARY_PASSWORD="app-specific-password"
```

The scripts must not print secret values. A future credentialed release pass must provide:

- `DWB_SIGNING_IDENTITY` with a Developer ID Application identity.
- `DWB_INSTALLER_SIGN_IDENTITY` with a Developer ID Installer identity when building a public `.pkg`.
- `DWB_NOTARY_KEYCHAIN_PROFILE`, or Apple ID/team/app-specific-password variables.
- `DWB_ALLOW_NOTARIZATION_UPLOAD=1` or `--allow-notarization-upload`.
- Human confirmation that the distribution channel is Developer ID outside the Mac App Store.

Useful read-only checks:

```sh
xcrun notarytool --help
xcrun stapler help
```

## Release packaging modes

Local ZIP draft:

```sh
./scripts/package-release.sh
```

This builds or verifies `dist/dwb xtreme.app`, creates a ZIP, checksum, manifest, and draft notes, and records the local signing/Gatekeeper status. It does not notarize or upload.

Public ZIP release candidate:

```sh
DWB_SIGNING_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
DWB_NOTARY_KEYCHAIN_PROFILE="profile-name" \
DWB_ALLOW_NOTARIZATION_UPLOAD=1 \
./scripts/package-release.sh --release
```

The script signs the app with Developer ID Application + Hardened Runtime, creates a ZIP, submits the ZIP for notarization, staples the staged app, recreates the ZIP with the stapled app, submits that final ZIP for notarization confirmation, extracts the final ZIP, and records `codesign`, stapler, and `spctl` verification for the extracted app. The ZIP is still local until a human publishes it.

Check release packaging inputs without building or upload:

```sh
./scripts/package-release.sh --check-release-inputs
```

Local installer draft:

```sh
./scripts/build-installer.sh
```

Public installer release candidate:

```sh
DWB_SIGNING_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
DWB_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Example, Inc. (TEAMID)" \
DWB_NOTARY_KEYCHAIN_PROFILE="profile-name" \
DWB_ALLOW_NOTARIZATION_UPLOAD=1 \
./scripts/build-installer.sh --release
```

The installer release mode signs the app with Developer ID Application + Hardened Runtime, signs the pkg with Developer ID Installer, submits the exact pkg for notarization, staples the pkg, validates the staple, and records `spctl -a -vv -t install` verification.

Check installer release inputs without building or upload:

```sh
./scripts/build-installer.sh --check-release-inputs
```

## App Sandbox and entitlements

P83 does not add an entitlements file and does not enable App Sandbox.

The practical reason is that `dwb xtreme` is a local media player whose core workflows depend on user-selected files and folders, recursive folder import, drag-and-drop/open-with flows, persisted recent/bookmarked local paths, Reveal in Finder, and user-triggered rename operations. Adopting App Sandbox safely would require a dedicated design pass for security-scoped bookmark storage, access renewal, stale bookmark handling, folder recursion permissions, rename behavior, VLCKit file access, and user-facing failure recovery.

Until that design exists, the honest posture is: Developer ID + Hardened Runtime + notarization/stapling for public binaries, with App Sandbox deferred and explicitly disclosed.

## Gatekeeper language

Use signing terms narrowly:

- Ad-hoc signed is not Developer ID signed.
- Self-signed is not Developer ID signed.
- Signed is not notarized.
- Notarized is not stapled unless stapler verification confirms it.
- Gatekeeper-ready requires appropriate signing, notarization, and verification of the exact artifact being distributed.

Do not claim Gatekeeper readiness for `dist/dwb xtreme.app` unless `spctl -a -vv "dist/dwb xtreme.app"` accepts it and the signing/notarization status supports that claim.
