<p align="center">
  <img src="docs/images/dwb-icon.png" alt="dwb app icon" width="144">
</p>

<h1 align="center">dwb video player</h1>

<p align="center">
  A lightweight macOS video player built for fast queueing, multi-window playback, and local media control.
</p>

<p align="center">
  <img src="docs/images/dwb-hero.png" alt="dwb video player main window" width="900">
</p>

## Overview

dwb video player is a native AppKit media player for macOS 13 and newer. Version 4.1.2 focuses on local playback, quick queue building, independent player windows, and practical controls for working through files on disk.

Playback is powered by VLCKit through Swift Package Manager. The app is local-media only: it does not provide streaming, cloud sync, telemetry, transcoding, or media-library management.

## Features

### Playback

- Native Swift and AppKit macOS application with programmatic UI.
- VLCKit-backed local video playback.
- Common local video formats: `mp4`, `m4v`, `mov`, `avi`, `flv`, `f4v`, `wmv`, `asf`, `mkv`, `ts`, `mts`, `m2ts`, `m2t`, `mpg`, `3gp`, `3g2`, `vob`, `ogv`, and `ogm`.
- Still-image and animated GIF playback with configurable slideshow duration and GIF loop count. Supported image formats: `jpg`/`jpeg`, `png`, `gif`, `tiff`, `bmp`, `heic`, `heif`, and `webp`.
- Drag-and-drop, Finder/Open With, Dock open, menu open, and folder expansion for supported media.
- Top-insert behavior for explicitly opened or dropped files so new files can be queued quickly.
- Play/pause, previous/next, configurable rewind/forward skip controls, scrubber seeking, volume, mute, fullscreen, Fit/Fill/Stretch scale modes, and Keep Window On Top.
- Repeat One plus a three-state shuffle cycle: Off, Shuffle, and Endless Shuffle.
- Stop isolation, stop-to-Queue-Page flow, paused-near-end completion handling, and queue restart from the beginning after natural completion.

### Queue

- Full Queue Page with filename, duration, file size, and total queue duration.
- Manual queue ordering by row drag, plus column-header sorting by File, Duration, or Size; clicking a header toggles ascending/descending order.
- Single-click row selection and double-click-to-play.
- Multi-select queue operations, Remove All, and Delete/Backspace removal for selected rows.
- Reveal in Finder and rename current file actions (via menu or `⌘R`).
- Optional one-click `x_` prefix rename for the current file (player page button and Queue Page button), including the `q` key binding. Works for videos, images, and GIFs.
- Optional custom-prefix rename for the current file (player page button and Queue Page button). Works for videos, images, and GIFs.
- Quick Queue support, including an optional setting to open the Queue Page when a player window opens.

### Windows And Controls

- Multiple independent player windows, each with its own playback state.
- Per-window volume and mute state, with persisted volume used as the default for new windows.
- Command+4 Four Window Grid layout for arranging four player windows.
- Unified bottom rail with optional transport buttons and auto-hide behavior.
- Draggable, resizable fallback control pod with persisted placement.
- Optional titlebar auto-hide and Complete Video Mode for windowed fill playback.
- Per-window opacity slider from 35% to 100%.

### Settings And Developer Support

- Settings window organized into Playback, Controls, Queue & Files, and Developer sections.
- Configurable skip duration, slideshow duration, GIF loop count, optional transport buttons, Queue Page behavior, rename options, titlebar behavior, complete video mode, rail behavior, and window opacity.
- Developer/debugging support through the Debug Console with filtering, snapshots, export, and optional verbose autoplay tracing.

## Screenshots

<p align="center">
  <img src="docs/images/dwb-four-window-grid.png" alt="Four independent player windows arranged in a grid" width="900">
</p>

<p align="center">
  <img src="docs/images/dwb-queue.png" alt="Queue Page with durations, file sizes, sorting, and total duration" width="760">
</p>

<p align="center">
  <img src="docs/images/dwb-settings.png" alt="Settings window with playback, controls, queue, and developer sections" width="740">
</p>

## Requirements

- macOS 13 or newer
- Xcode with command line tools
- Swift 5.9-compatible toolchain
- Network access for Swift Package Manager on first build, unless VLCKit is already cached locally
- Optional: `xcodegen` to regenerate `dwb/dwb.xcodeproj` from `dwb/project.yml`

## Build From Source

Build the app from the repository root:

```sh
./scripts/build-app.sh
```

The script builds the `dwb` scheme in Release configuration and copies the app bundle to:

```text
dist/dwb.app
```

It also writes local build metadata to:

```text
dist/dwb-app-build-info.txt
```

Create a local ZIP package, checksum, manifest, and draft release notes:

```sh
./scripts/package-release.sh
```

Release packaging artifacts are written under a versioned folder such as `dist/release/dwb-vplayer-4.1.2/`. The ZIP workflow verifies the built app and extracted app locally, but it does not publish a GitHub Release, upload assets, notarize, staple, tag, or commit anything.

If `project.yml` changes and you need to regenerate the Xcode project:

```sh
cd dwb
xcodegen generate --spec project.yml
cd ..
./scripts/build-app.sh
```

## Release Status / Signing Note

This repository currently provides source code only. It does not publish signed or notarized release downloads, installer packages, App Store builds, or release assets.

Local builds are ad-hoc signed for local `codesign` verification by default, but they are not Developer ID signed, notarized, stapled, or Gatekeeper-ready. See `docs/SIGNING.md` for the local signing workflow and verification commands.

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

MIT. See `LICENSE`.

This repository's MIT license applies to this app's source code, not to VLCKit, libVLC, or other third-party dependencies.
