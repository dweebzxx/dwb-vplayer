# AGENT.md — dwb video player

This file must be listed first in the read-first section of every AI assistant prompt and read at the start of every AI assistant pass. Neither Codex nor Claude auto-reads `AGENT.md`. It encodes stable project constraints that apply to all future implementation, documentation, and workflow passes.

---

## Project Identity

- **Name:** dwb video player
- **Version at last write:** 4.1.2 (build 412)
- **Language:** Swift
- **Frameworks:** AppKit, VLCKit (via `tylerjonesio/vlckit-spm` through Swift Package Manager)
- **Platform:** macOS 13+
- **Scope:** Local media playback only
- **Build configuration:** Release
- **Canonical app artifact:** `dist/dwb.app`

---

## Architecture Constraints

- AppKit application. No SwiftUI, no storyboards, no XIBs, no Interface Builder.
- All UI is built programmatically.
- Per-window playback state. Each `PlayerWindowController` owns its own `VLCMediaPlayer` instance. Do not introduce shared player state between windows.
- VLCKit is the only media playback dependency. Do not add dependencies without explicit instruction in the prompt.
- No streaming, cloud sync, transcoding, subtitle workflow, media library, analytics, telemetry, or network features unless a future prompt explicitly requests them.

---

## UI Constraints

- No storyboards, XIBs, or Interface Builder usage of any kind.
- Do not write titlebar chrome changes inside `windowDidResize`. That method body must remain: log + `layoutPlayerViews()` only.
- Transport controls, bottom rail, and Queue Page layout follow the patterns established through P38. Do not restructure view hierarchy unless a future prompt explicitly requests it.

---

## Playback and Queue Constraints

Preserve the following behavior unless a future pass explicitly changes it:

- Queue, shuffle (three-state cycle: Off → Shuffle → Endless → Off), repeat one
- Stop isolation (intentional Stop does not trigger autoplay)
- Stop-to-Queue-Page flow
- Paused-near-end completion handling
- Top-insert behavior for explicitly opened or dropped files
- Image/GIF slideshow playback (via AppKit/NSImage, not VLCKit)
- Volume persistence via `persistedVolume` / UserDefaults
- Fullscreen and windowed layout behavior
- Titlebar and window chrome behavior
- Bottom rail auto-hide
- Queue Page: single-click selects only, double-click plays; multi-select; Delete/Backspace removes selected rows
- Custom prefix rename (configurable via Settings; replaces former d_/delete_ rename)
- x_ prefix rename and `q` key binding
- Rail buttons and Quick Queue behavior
- Total queue duration display
- Control-pod drag and placement persistence

---

## File Operation Safety

- Do not modify user media files except through explicit user-triggered app file operations (rename, delete-prefix rename) that the user has initiated in the running app.
- Do not read, copy, move, or delete files outside the repository working directory.
- Do not write to `dist/` unless running `./scripts/build-app.sh` as part of a build-required pass.

---

## Build and Validation Expectations

For every **implementation pass**:

1. Run `git status --short` before making any changes.
2. Run `git status --short` and `git diff --stat` after changes.
3. Run `./scripts/build-app.sh` to verify the build succeeds.
4. Report pre-existing baseline changes separately from pass-local changes.

For **documentation-only or workflow-only passes** (no source file changes):

1. Run `git status --short` before and after.
2. Run `git diff --stat`.
3. Verify created/modified files exist and are valid (e.g., JSON validity for `.json` files).
4. Do **not** run `./scripts/build-app.sh` unless a source file was changed by mistake.

If source files are changed by mistake during a documentation-only pass, revert those changes and document the correction in the report.

`scripts/build-app.sh` is the canonical build entry point. Do not invoke `xcodebuild` directly unless the script itself is being modified. When packaging is explicitly required and `scripts/build-installer.sh` exists, `scripts/build-installer.sh` is the canonical package entry point.

For build-required passes, canonical verification is:

1. `scripts/build-app.sh`
2. `dist/dwb.app` exists
3. `dist/dwb.app/Contents/Info.plist` version checks match expected `CFBundleShortVersionString` and `CFBundleVersion`
4. codesign/spctl status recorded when applicable
5. metadata JSON validates with `python3 -m json.tool "$AI_METADATA_PATH"`

---

## Pass Artifact Expectations

Every pass must produce:

- **Markdown report** written to `AI_REPORT_PATH` (conventionally `build-report-logs/reports/<date>_<PNN>_<slug>-report.md`)
- **Metadata JSON** written to `AI_METADATA_PATH` (conventionally `build-report-logs/metadata-reports/<date>_<PNN>_<slug>-metadata.json`)

`AGENT.md` and `metadata-schema.json` live at the project root and are intended to be version-controlled. `build-report-logs/` is local-only and git-ignored.

Artifact locations:

- Raw logs: `build-report-logs/logs/raw-logs/`
- Clean logs: `build-report-logs/logs/clean-logs/`
- Meta logs: `build-report-logs/logs/meta-logs/`
- Markdown reports: `build-report-logs/reports/`
- Metadata JSON: `build-report-logs/metadata-reports/`
- Prompts: `build-report-logs/prompts/`

The metadata JSON must conform to `metadata-schema.json` at the project root.

After writing `AI_METADATA_PATH`, validate it with `python3 -m json.tool "$AI_METADATA_PATH"` and confirm it is valid JSON.

Date prefix format: `YY-MM-DD` (e.g., `26-05-09`).

Do not overwrite `AI_PROMPT_PATH`.

Agents must always write `duration_seconds` and `total_tokens_used` as `null`. Do not estimate either field. After the interactive session exits, `scripts/ai-post-pass.zsh` patches those fields from the meta file and clean log when values are available; it preserves `null` when unavailable.

Normal implementation, documentation, and workflow passes must not modify `AGENT.md` or `metadata-schema.json`. Only dedicated bootstrap/maintenance passes may modify those project-root workflow files.

`scripts/ai-post-pass.zsh` is a committed workflow helper created and maintained only by bootstrap/maintenance passes. v5.8.1 launchers auto-invoke it after the assistant session exits to validate pass artifacts and patch post-session metrics when available.

---

## Workflow State Check

At the start of every pass, verify and record in the metadata JSON:

- `agent_md_present`: `true` if `AGENT.md` exists at the project root.
- `schema_present`: `true` if `metadata-schema.json` exists at the project root.
- `gitignore_correct`: `true` if `build-report-logs/` appears in `.gitignore`.

`AGENT.md`, `metadata-schema.json`, and `scripts/ai-post-pass.zsh` are project-root workflow files intended to be version-controlled. `build-report-logs/` is local-only and must remain git-ignored. Its subdirectories (`logs/`, `logs/raw-logs/`, `logs/clean-logs/`, `logs/meta-logs/`, `reports/`, `metadata-reports/`, `prompts/`) are created on first use and are never committed.

Every pass report must include this fixed five-row v5.8.1 Workflow State table exactly:

| Item | Status |
|---|---|
| AGENT.md present at project root | yes / no |
| metadata-schema.json present at project root | yes / no |
| build-report-logs/ in .gitignore | yes / no |
| Prompt template for next pass | lean (§13) / full (§14) |
| Bootstrap pass needed | yes / no |

Replace each `yes / no` and `lean (§13) / full (§14)` placeholder with the actual status. If all first three rows are `yes`, the report must include this exact sentence:

Workflow fully initialized for v5.8.1. Use lean prompt template for next pass.

---

## Prohibited Actions

The following actions are **never permitted** unless explicitly authorized by the specific prompt:

- `git commit`, `git push`, `git tag`, `git push --tags`
- Notarization, code signing, packaging, publishing, or releasing
- Installing the built app to `/Applications` or any system location
- Upgrading or downgrading dependencies
- Changing `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` (version bumps require explicit prompt instruction)
- Deleting or overwriting user media files
- Modifying `AI_PROMPT_PATH`

---

## Reporting Expectations

Every pass report must include:

- Status (e.g., `COMPLETE`, `BUILD_SUCCEEDED`, `DOCUMENTATION_ONLY`)
- Model used
- Files read
- Files created
- Files modified (pass-local changes only, separated from pre-existing baseline)
- Exact behavior or workflow changes made
- Validation commands run and their outcomes
- Confirmation that no app behavior or source changes were made (for documentation-only passes)
- Confirmation that no build was run (for documentation-only passes, unless a build was accidentally triggered)
- Known limitations or intentional non-changes
- Confirmation that no commit, push, tag, publish, notarization, signing, install, release, or user media mutation occurred
- The fixed v5.8.1 Workflow State table from this file

If any required item cannot be completed safely, document the incomplete item and explain the blocker. Complete the rest of the pass.

---

## Notes for Future Passes

- Always include AGENT.md first in the read-first list. Neither Codex nor Claude auto-reads it.
- The `build-report-logs/` directory is git-ignored. Its contents are local only and must not be committed.
- The `dist/` directory is git-ignored. Build output is local only.
- `scripts/build-app.sh` is the canonical build entry point. Do not invoke `xcodebuild` directly unless the script itself is being modified.
