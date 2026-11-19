# YTA

A native macOS app for running faceless YouTube channels, from a niche to a finished upload folder. For personal use. YTA does not upload: you upload each video yourself.

The full plan is in [docs/specification.md](docs/specification.md).

## Requirements

- macOS 26 or later on Apple silicon
- Command Line Tools (`xcode-select --install`). Xcode is not needed.
- Node.js, for Remotion
- At least one of Claude Code, Codex or OpenCode, signed in

## Build and run

```bash
git clone -b main https://github.com/hozaifahejaz/YTA.git
cd YTA
Scripts/build-app.sh            # builds build/YTA.app
open build/YTA.app
```

`Scripts/build-app.sh --install` also copies the app to `~/Applications`. The app is signed ad hoc, which is enough to run it on the Mac that built it.

For quick work on the code, `swift run YTA` starts the app without making a bundle, and `swift test` runs the tests.

`swift run yta-engine-check` runs one small step through each installed engine (Claude Code, Codex, OpenCode) in a throwaway channel and reports the result.

`swift run yta-youtube-check [@handle]` checks a handle and takes a channel snapshot against live YouTube, through the API if a key is saved in Settings and through public pages either way. Add `--pages-only` to skip the API.

The Command Line Tools do not include SwiftUI's macro plugin, so YTA never uses `@State`. Views keep local state in `LocalState` instead (see `Sources/DesignSystem/LocalState.swift`).

## Where things live

| What | Where |
|---|---|
| Channels | `~/YouTube Automation/Channels/<Channel Name>/` |
| Research not tied to a channel | `~/YouTube Automation/Research/` |
| Settings, tool paths, templates, logs | `~/Library/Application Support/YTA/` |
| API keys | Keychain, service `YTA` |

Each channel is one folder that holds everything about it, including `AGENTS.md`, the instructions every engine reads first. The storage folder can be changed in Settings.

## Layout

| Module | Role |
|---|---|
| `Support` | Errors, atomic file writes, JSON, settings, logging with secret redaction, process runner |
| `ChannelStore` | Channel folders, path guard, history snapshots, `AGENTS.md`, folder watching |
| `Workflow` | Node types, the editable rows, dependencies, templates |
| `Engines` | Health check; Claude Code, Codex and OpenCode adapters; plan defaults |
| `Secrets` | Keychain storage for API keys |
| `DesignSystem`, `Canvas`, `YTAApp` | The interface (macOS only) |

The core modules use Foundation only, so their tests also run on Linux in CI.

## Status

Built in the milestone order of section 11 of the specification.

- [x] 0. Proof of build: Swift package, app bundle script, ad hoc signing, CI
- [x] 1. Foundation: design system, window, sidebar, canvas, inspector, Settings, Keychain, health check, storage folder
- [x] 2. Channel store: folder layout, path guard, atomic writes, folder watching, history
- [x] 3. Workflow engine: run state machine, crash resume, notifications, menu bar
- [x] 4. Engines: Claude Code, Codex and OpenCode adapters, clean environment, run logs, result checks, plan defaults
- [x] 5. YouTube data: Data API client, quota ledger, page fallback, handle check, channel snapshot
- [x] 6. Naming, brand, profile picture, banner, setup kit, playbook
- [x] 7. Skills and niche research
- [x] 8. Import
- [x] 9. Queue, topic research, script pipeline
- [x] 10. Voice: ai33pro client, v4 lock, voice pick, narration and timings (locked until the v4 setting is confirmed)
- [x] 11. Media: source clients, licence rules, ledger, ranking, review board, music library
- [x] 12. Editing: timeline, Remotion project, Studio review, render queue, final check
- [x] 13. Finishing: thumbnail style, thumbnails, YouTube Kit.docx, credits, final gate, calendar, learning loop
- [ ] 14. Automation dial, cost caps and disk controls are built; the unattended run on a test channel is still to do
