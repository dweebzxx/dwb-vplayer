# dwb video player

Version 2.0.1

dwb video player is a lightweight macOS local video player built with Swift, AppKit, and VLCKit. It focuses on fast local playback, queue control, and a native macOS app feel without SwiftUI, storyboards, cloud features, streaming, or library management.

## Features

- Plays local video files in independent player windows.
- Supports opening files from Finder, Open With, drag and drop, the Dock icon, and the app menu.
- Handles multi-window playback without sharing player state between windows.
- Queue Page with sorting by name, file size, and duration.
- Queue reordering, remove-from-queue, right-click queue actions, and file rename support.
- Regular autoplay, Repeat One, shuffle, and endless shuffle.
- Stop isolation so an intentional Stop does not trigger autoplay.
- Stop-to-Queue-Page flow for inspecting or changing the queue after stopping.
- Paused-near-end completion handling for reliable queue advancement.
- Top-insert behavior for explicitly opened or dropped files, with immediate playback of the first inserted file.
- Total queue duration display.
- Persistent volume, skip duration, optional transport controls, and draggable control-pod placement.
- Stable titlebar and native fullscreen/windowed layout behavior.

## Supported Formats

dwb accepts these filename extensions:

- `.mp4`
- `.mov`
- `.avi`
- `.flv`
- `.wmv`
- `.mkv`
- `.ts`
- `.mpg`

Playback is provided by VLCKit/libVLC, so actual codec support follows the embedded VLCKit build.

## Install And Run

If you already have a built app:

1. Open `dist/dwb.app`.
2. Use File > Open, drag files into the player, or choose dwb from Finder's Open With menu.
3. For a first local unsigned build, macOS Gatekeeper may require Control-clicking the app, choosing Open, and confirming the launch.

This repository does not include notarization, a Developer ID signature, a DMG, or App Store packaging.

## Build From Source

Requirements:

- macOS 13 or newer
- Xcode with command line tools
- Swift 5.9-compatible toolchain
- Network access for Swift Package Manager on first build, unless VLCKit is already cached locally
- Optional: `xcodegen` if you want to regenerate `dwb/dwb.xcodeproj` from `dwb/project.yml`

Build the app:

```sh
./scripts/build-app.sh
```

The script builds the `dwb` scheme and copies the finished app to:

```text
dist/dwb.app
```

It also writes local build metadata to:

```text
dist/dwb-app-build-info.txt
```

To regenerate the Xcode project when `project.yml` changes:

```sh
cd dwb
xcodegen generate --spec project.yml
```

Then build again from the repository root:

```sh
./scripts/build-app.sh
```

## Basic Usage

- Open one or more supported files with File > Open.
- Drop files onto the player window to add them to the active queue.
- Drop folders to load supported media files from the folder recursively.
- Use the Queue Page to sort, reorder, remove, rename, reveal files in Finder, and inspect total duration.
- Use playback menu items or visible transport buttons for play/pause, Stop, skip, volume, shuffle, endless shuffle, and Repeat One.
- Open additional independent windows with Command-N.

## Settings

The Settings window includes:

- Skip duration for backward and forward jumps.
- Optional transport controls for Stop, Volume, Shuffle, Repeat, and Quick Queue.
- Auto-hide controls behavior.

Volume and control-pod placement persist through user defaults.

## Repository Structure

```text
dwb/
  project.yml
  dwb.xcodeproj/
  dwb/
    App/
    Player/
    Resources/
scripts/
  build-app.sh
```

Local build output appears under `dist/` and is intentionally ignored by git to keep the source repository lightweight.

## Dependency Notes

dwb uses `tylerjonesio/vlckit-spm` through Swift Package Manager. VLCKit and libVLC are third-party components with their own licensing terms. This repository's MIT license applies to this app's source code, not to VLCKit, libVLC, or any other third-party dependency.

## Known Limitations

- Local files only; no streaming, transcoding, subtitles workflow, or media library management.
- Builds are local and unsigned unless you add your own signing configuration.
- Gatekeeper may warn on locally built app bundles.
- Playback behavior depends on VLCKit/libVLC support for the file's container and codecs.
- Runtime validation should be performed on a normal macOS desktop with real media files; headless or sandboxed environments may not launch AppKit bundles correctly.

## License

MIT. See `LICENSE`.
