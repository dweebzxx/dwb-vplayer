# dwb xtreme Agent Guide

This checkout is the `xtreme` split-off branch/worktree for `dwb xtreme`. Keep future work on `xtreme` unless the user explicitly instructs otherwise. Do not merge, push, or port xtreme-only work back to `main` without explicit authorization.

## Project Snapshot

- Native macOS media player built with Swift, AppKit, and VLCKit.
- Source lives under `dwb/dwb/`.
- Xcode project lives at `dwb/dwb.xcodeproj`; `dwb/project.yml` is the XcodeGen source if project regeneration is required.
- Local build output is written under `dist/` and generated build state under `.tmp/`; both are local-only.
- `build-report-logs/` is local-only workflow output and must not be committed.

## Branch Rules

- Required implementation branch for this worktree: `xtreme`.
- Confirm branch with `git branch --show-current` before workflow or implementation passes.
- Stop and report BLOCKED if this checkout is not on `xtreme`.
- Do not push unless the user explicitly requests it.

## Build And Verification

- Standard local app build from the repository root:

```sh
./scripts/build-app.sh
```

- Local release packaging:

```sh
./scripts/package-release.sh
```

- Installer packaging:

```sh
./scripts/build-installer.sh
```

- Release input checks only:

```sh
./scripts/package-release.sh --check-release-inputs
./scripts/build-installer.sh --check-release-inputs
```

- Do not run build, package, signing, notarization, installer, upload, publish, tag, or release commands unless the pass specifically authorizes them.
- Never print or copy secrets, signing credentials, notary credentials, private keys, keychains, provisioning profiles, or environment values that may contain credentials.

## Workflow Baseline

- Workflow guide version: v6.2.
- Root workflow files are `AGENT.md`, `metadata-schema.json`, `scripts/ai-post-pass.zsh`, and `scripts/ai-tool-preflight.zsh`.
- Pass reports and metadata belong under `build-report-logs/`.
- Reports must honestly list files read, files created, files modified, verification performed, unresolved issues, and the recommended next prompt.
- Metadata JSON must parse and include all required v6.2 fields.
- Use `WORKFLOW_ONLY` for workflow/bootstrap-only passes and `DOCUMENTATION_ONLY` for docs-only passes. Use build statuses only when a build was actually performed.

## Editing Constraints

- Do not modify application source files during bootstrap/adoption workflow passes.
- Keep changes scoped to the user-requested pass.
- Preserve existing signing, notarization, sandbox, and release posture unless the pass explicitly targets those areas.
- Do not edit generated output, caches, `dist/`, `.tmp/`, user media, or local-only logs except the current pass report/metadata.
- If `Package.resolved`, `project.pbxproj`, signing files, or release scripts appear to need changes, verify that the current pass authorizes that scope before editing.

## Project Notes

- The public-facing app naming must remain uniform as `dwb xtreme` in menus, bundle/display names, settings/about copy, and default player-window titles unless a future prompt explicitly renames the app.
- README describes version 1.3.0 and macOS 13+ requirements.
- VLCKit is resolved through Swift Package Manager using the pinned dependency in the Xcode project workspace state.
- Local source builds use ad-hoc signing by default; Developer ID signing, notarization, stapling, uploads, and public release publication require explicit authorization.
