# Signing dwb video player

This document describes the local macOS signing workflow for `dwb.app`.

This workflow does not notarize the app, create a GitHub release, upload artifacts, or make the app Gatekeeper-ready unless Developer ID signing and notarization are explicitly completed and verified.

## Current local build mode

The canonical build command is:

```sh
./scripts/build-app.sh
```

By default, the build script produces `dist/dwb.app` and then runs:

```sh
scripts/sign-app.sh --app dist/dwb.app --adhoc --no-timestamp
```

That fixes the previous malformed linker/ad-hoc posture by applying a real bundle signature with sealed resources and a bound `Info.plist`. It is still only ad-hoc signed, not Developer ID signed, not notarized, and not stapled.

To build without signing:

```sh
DWB_SKIP_SIGN=1 ./scripts/build-app.sh
```

## Signing script

Run the signing script directly when you need to sign or verify an existing app bundle:

```sh
scripts/sign-app.sh --app dist/dwb.app --adhoc
scripts/sign-app.sh --app dist/dwb.app --verify-only
```

Options:

```text
--app <path>          App bundle to sign or verify. Default: dist/dwb.app
--identity <name>     Signing identity name or hash. Default: DWB_SIGNING_IDENTITY
--adhoc              Sign with ad-hoc identity "-"
--timestamp          Request timestamp signing for non-ad-hoc identities
--no-timestamp       Disable timestamp signing
--verify-only        Do not sign; only run verification checks
--help               Show help text
```

If no identity is provided and `--adhoc` is not provided, the script signs ad-hoc with identity `-`.

The script does not create, export, import, print, or delete certificates, private keys, keychains, credentials, or provisioning profiles. It may print the signing identity name that was provided or made visible by local tools.

## Ad-hoc signing

Ad-hoc signing is the default local workflow:

```sh
scripts/sign-app.sh --app dist/dwb.app --adhoc
```

Ad-hoc signing can make `codesign --verify --deep --strict` pass for local build hygiene. It does not identify a developer to macOS Gatekeeper and does not make the app suitable as a public release download.

Expected verification shape for ad-hoc builds:

```sh
codesign --verify --deep --strict --verbose=4 dist/dwb.app
codesign -dv --verbose=4 dist/dwb.app
spctl -a -vv dist/dwb.app
```

`codesign` should pass. `spctl` can reject the app because ad-hoc signing is not Developer ID signing and the local workflow does not notarize.

## Self-signed or local certificate signing

If you have a local code-signing certificate already available in your keychain, use it explicitly:

```sh
scripts/sign-app.sh --app dist/dwb.app --identity "Your Local Signing Identity" --no-timestamp
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
DWB_SIGNING_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" DWB_SIGN_TIMESTAMP=1 ./scripts/build-app.sh
```

The timestamp option is appropriate for Developer ID signing. This project does not provision Developer ID credentials and does not select a Developer ID identity automatically.

## Notarization and stapling

Developer ID signing alone is not notarization. A public macOS download normally needs:

1. Developer ID Application signing.
2. Submission to Apple notarization.
3. Successful notarization result.
4. Stapling where applicable.
5. Verification of the final distributed artifact.

The local build workflow intentionally does not run `xcrun notarytool submit`, does not use Apple ID credentials or keychain profiles, and does not run `xcrun stapler staple`.

Useful read-only checks:

```sh
xcrun notarytool --help
xcrun stapler help
```

## Gatekeeper language

Use signing terms narrowly:

- Ad-hoc signed is not Developer ID signed.
- Self-signed is not Developer ID signed.
- Signed is not notarized.
- Notarized is not stapled unless stapler verification confirms it.
- Gatekeeper-ready requires appropriate signing, notarization, and verification of the exact artifact being distributed.

Do not claim Gatekeeper readiness for `dist/dwb.app` unless `spctl -a -vv dist/dwb.app` accepts it and the signing/notarization status supports that claim.
