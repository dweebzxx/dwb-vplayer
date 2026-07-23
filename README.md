<p align="center">
  <img src="docs/images/dwb-icon.png" alt="dwb player app icon" width="144">
</p>

<h1 align="center">dwb player</h1>

<p align="center">
  A native macOS media player for fast local queueing, multi-window playback, and practical file controls.
</p>

<p align="center">
  <img src="docs/images/dwb-hero.png" alt="dwb player main playback window with bottom rail controls" width="900">
</p>

## Overview

dwb player is a native Swift/AppKit media player for macOS 13 and newer. The latest public source release is 4.2.2. This checkout contains locally implemented, not-yet-published 4.2.4 work; do not describe 4.2.4 as released until it is committed, pushed, tagged, and released. The app focuses on local media playback, fast queue building, independent player windows, Finder-style file ordering, and direct controls for working through files on disk.

Playback is powered by VLCKit through Swift Package Manager. dwb player is local-only: it does not provide streaming, cloud sync, telemetry, transcoding, or media-library management.

## Current Release Highlights (v4.2.2)

- Standardized public app naming to `dwb player` across the interface and documentation.
- Refreshed Settings and About sections with updated attributions and links.
- Hardened multi-window autoplay transitions by reusing the VLCKit player during normal auto-advance to prevent configuration hangs.

## Unreleased (local work)

- Native Queue search clear action.
- Still-image slideshow durations include 0.5 and 0.75 seconds.
- Filtered/bookmarked Queue multi-selection deletion supports Delete, Backspace, and Forward Delete while preserving safe row mapping and context targeting.
- Persistent, nonmodal, per-window intake recovery for unsupported or disabled media, empty/failed folder scans, rescans, and unavailable folders.
- Current Queue Page visual/stability improvements, including corrected accent treatment and guarded row rendering.
- Keyboard focus/accessibility state and stable automation identifiers for applicable rail, Queue, recovery, and Settings controls.
- Responsive rail and Queue layouts, filtered-empty recovery, responsive Queue footer/prefix overflow, scanning presentation, refined Settings/About layout, title overlay, and quiet Queue/video divider.
- Obsolete Queue Duration/Size visibility controls removed while metadata remains on cards.
- About action label: `View on GitHub`.

## Features

### Playback

- Native Swift and AppKit macOS application with a programmatic UI.
- VLCKit-backed local video playback.
- Common local video formats: `mp4`, `m4v`, `mov`, `avi`, `flv`, `f4v`, `wmv`, `asf`, `mkv`, `ts`, `mts`, `m2ts`, `m2t`, `mpg`, `3gp`, `3g2`, `vob`, `ogv`, and `ogm`.
- Still-image and animated GIF playback with configurable slideshow duration and GIF loop count. Supported image formats: `jpg`, `jpeg`, `jfif`, `png`, `gif`, `tiff`, `tif`, `bmp`, `heic`, `heif`, and `webp`.
- Still-image slideshow intervals include 0.5 and 0.75 seconds in addition to the existing choices.
- Drag-and-drop, Finder/Open With, Dock open, menu open, and recursive folder expansion for supported local media files.
- Folder import uses Finder-style natural filename ordering by display filename, with deterministic path tie-breaks.
- Top-insert behavior for explicitly opened or dropped files, so new files can be queued quickly.
- Play/pause, previous/next, configurable rewind/forward skip controls, scrubber seeking, fullscreen, Fit/Fill/Stretch scale modes, Keep Window On Top, and optional titlebar auto-hide.
- Per-window volume, mute, playback speed, opacity, and playback state. Persisted volume is used as the default for new windows.
- Repeat One plus a three-state shuffle cycle: Off, Shuffle, and Endless Shuffle.
- Stop isolation, stop-to-Queue-Page flow, paused-near-end completion handling, and queue restart from the beginning after natural completion.

### Queue

- Full Queue Page with filename, duration, file size, search/filter, bookmark filter, and total queue duration.
- Queue search has a native clear action.
- Manual queue ordering by row drag, plus sort modes for Name A-Z, Name Z-A, Size Low-High, Size High-Low, Duration Short-Long, and Duration Long-Short.
- Name A-Z and Name Z-A sorting use the same Finder-style natural filename comparison as folder import.
- Single-click row selection and double-click-to-play.
- Filtered/bookmarked multi-selection supports Delete, Backspace, and Forward Delete; context actions retain their clicked-row target.
- Multi-select queue operations, selected-row Delete/Backspace removal, Remove All, Clear Queue, and rescan.
- The card-style Queue Page no longer offers separate Duration/Size column toggles; that metadata remains on each card.
- Reveal in Finder and rename current file actions from the app menu or queue context actions.
- Bookmark toggles in the playback controls, queue rows, and Queue Page filter.
- Quick Queue support, including an optional setting to open the Queue Page when a player window opens.

### Accessibility and Recovery

- Keyboard-focusable rail and Queue controls expose labels and state; hidden rail controls leave focus and accessibility navigation. (VoiceOver/Full Keyboard Access visual verification is pending, not complete.)
- Local-media intake errors stay in-window with safe recovery actions and preserve the current queue/playback state.

### Prefix Rename

- Dual configurable prefix rename for videos, images, and GIFs.
- The primary prefix is applied with `Q`; the secondary prefix is applied with `Option-Q`.
- Player and Queue Page prefix buttons can apply the configured prefix without opening a rename dialog.
- Player and bottom-rail prefix buttons show the first configured character plus `_`; Queue Page footer prefix labels show the trimmed full prefix up to 8 characters, truncating longer labels with an ellipsis.
- Queue highlighting recognizes both prefixes and prefers the longer matching prefix when both could match.
- Prefix identity colors are Dark Teal 500 `#488FA0` for primary and Burnt Orange 300 `#D4906A` for secondary.
- `x_` is only a possible user-configured prefix value; it is not a hard-coded rename mode.

### Windows And Controls

- Multiple independent player windows, each with its own VLCKit player state.
- Command-4 Four Window Grid layout for arranging four player windows.
- Unified bottom rail as the active control surface, with optional transport buttons, auto-hide behavior, bookmark control, prefix controls, and More menu fallback.
- More menu fallback for rail actions that do not fit in the active bottom rail.
- Complete Video Mode for windowed fill playback.
- Window opacity slider from 35% to 100%.

### Settings, Menus, And About

- Settings window sections: Playback, Controls, Queue & Files, Shortcuts, Advanced, and About.
- Configurable skip duration, slideshow duration, GIF loop count, accepted media types, optional playback-bar buttons, Queue Page behavior, rename options, titlebar behavior, Complete Video Mode, rail behavior, playback speed, and window opacity.
- About section identifies `dwb player`, shows the app version/build, mentions the MIT License, identifies AppKit and VLCKit, and links to the GitHub repository and issue tracker. The About page includes a "View on GitHub" action.
- Programmatic menus cover dwb player, File, Playback, Video, and Window actions including Settings, Open, Reveal in Finder, Rename, Remove Current from Queue, Clear Queue, New Window, playback controls, speed, scale mode, Four Window Grid, Keep Window On Top, and Auto-hide Titlebar.
- Developer/debugging support through the Debug Console with filtering, snapshots, export, and optional verbose autoplay tracing.

## Screenshots

<p align="center">
  <img src="docs/images/dwb-four-window-grid.png" alt="Four independent dwb player windows arranged in a grid" width="900">
</p>

<p align="center">
  <img src="docs/images/dwb-queue.png" alt="dwb player Queue Page showing current layout with search clear, sort, prefix actions, and total duration" width="900">
</p>

<p align="center">
  <img src="docs/images/dwb-settings.png" alt="dwb player Settings window over four playback windows" width="900">
</p>

## Requirements

- macOS 13 or newer
- Xcode with command line tools
- Swift 5.9-compatible toolchain
- Network access for Swift Package Manager on first build so Xcode can fetch the pinned VLCKit package and binary artifact recorded in `Package.resolved`
- Optional: `xcodegen` to regenerate `dwb/dwb.xcodeproj` from `dwb/project.yml`

## Build From Source

Build the app from the repository root:

```sh
./scripts/build-app.sh
```

The script builds the `dwb` scheme in Release configuration and copies the app bundle to:

```text
dist/dwb player.app
```

The default build path is the standard Xcode/SwiftPM path for the pinned `vlckit-spm` 3.6.0 dependency. Local generated Xcode state under `.tmp/derivedData/` may be cleared when stale absolute package artifact paths are detected after moving the repository. A cached VLCKit products fallback is disabled by default and is only for local development with `DWB_ALLOW_DEV_CACHED_VLCKIT_FALLBACK=1`; it is not release provenance.

It also writes local build metadata to:

```text
dist/dwb-player-app-build-info.txt
```

Create a local ZIP package, checksum, manifest, and draft release notes:

```sh
./scripts/package-release.sh
```

Release packaging artifacts are written under a versioned folder such as `dist/release/dwb-player-4.2.2/`. The ZIP workflow verifies the built app and extracted app locally, but it does not publish a GitHub Release, upload assets, notarize, staple, tag, or commit anything.

Public binary release mode is intentionally separate from local packaging. A future credentialed release pass must provide a Developer ID Application identity, notarytool credentials or profile, explicit notarization upload approval, and final Gatekeeper verification:

```sh
DWB_SIGNING_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
DWB_NOTARY_KEYCHAIN_PROFILE="profile-name" \
DWB_ALLOW_NOTARIZATION_UPLOAD=1 \
./scripts/package-release.sh --release
```

Installer release mode additionally requires a Developer ID Installer identity:

```sh
DWB_SIGNING_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
DWB_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Example, Inc. (TEAMID)" \
DWB_NOTARY_KEYCHAIN_PROFILE="profile-name" \
DWB_ALLOW_NOTARIZATION_UPLOAD=1 \
./scripts/build-installer.sh --release
```

Run the release input checks without signing, packaging, notarizing, or uploading:

```sh
./scripts/package-release.sh --check-release-inputs
./scripts/build-installer.sh --check-release-inputs
```

If `project.yml` changes and you need to regenerate the Xcode project:

```sh
cd dwb
xcodegen generate --spec project.yml
cd ..
./scripts/build-app.sh
```

## Release Status / Signing Note

This repository currently provides source code only. It does not publish signed or notarized release downloads, installer packages, App Store builds, or binary release assets. P83 defined the release hardening posture but did not publish a binary and did not use Apple credentials.

Local source builds and tests do not require Apple Developer Program membership. Local builds are ad-hoc signed for local `codesign` verification by default, but they are not Developer ID signed, notarized, stapled, sandboxed, or Gatekeeper-ready. Public binary release remains optional/deferred and requires Developer ID Application signing with Hardened Runtime, notarization, stapling where applicable, and recorded `spctl` verification of the exact release artifact before publication.

App Sandbox is not adopted yet. It remains a future design decision because local media playback, folder import, persisted local paths, and rename workflows need a deliberate security-scoped bookmark and file-access design before sandboxing can be enabled honestly. See [docs/SIGNING.md](docs/SIGNING.md) for the full signing, notarization, installer, and sandbox posture.

## Project Structure

```text
dwb/
  project.yml
  dwb.xcodeproj/
  dwb/
    App/
    Player/
    Resources/
docs/images/
scripts/
  build-app.sh

  build-installer.sh
  package-release.sh
  sign-app.sh
```

`dist/`, `.tmp/`, `DerivedData/`, build logs, archives, package outputs, signing material, and local user state are intentionally ignored by git.

## License

MIT. See [LICENSE](LICENSE).

This repository's MIT license applies to this app's source code, not to VLCKit, libVLC, or other third-party dependencies.
