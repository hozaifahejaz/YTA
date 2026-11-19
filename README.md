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
git clone https://github.com/hozaifahejaz/YTA.git
cd YTA
Scripts/build-app.sh            # builds build/YTA.app
open build/YTA.app
```

`Scripts/build-app.sh --install` also copies the app to `~/Applications`. The app is signed ad hoc, which is enough to run it on the Mac that built it.

For quick work on the code, `swift run YTA` starts the app without making a bundle, and `swift test` runs the tests.

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
| `Engines` | Health check now; Claude Code, Codex and OpenCode adapters next |
| `Secrets` | Keychain storage for API keys |
| `DesignSystem`, `Canvas`, `YTAApp` | The interface (macOS only) |

The core modules use Foundation only, so their tests also run on Linux in CI.

## Status

Built in the milestone order of section 11 of the specification.

- [x] 0. Proof of build: Swift package, app bundle script, ad hoc signing, CI
- [x] 1. Foundation: design system, window, sidebar, canvas, inspector, Settings, Keychain, health check, storage folder
- [x] 2. Channel store: folder layout, path guard, atomic writes, folder watching, history
- [ ] 3. Workflow engine: run state machine, crash resume, notifications
- [ ] 4. Engines
- [ ] 5. YouTube data
- [ ] 6. Naming, brand, profile picture, banner, setup kit, playbook
- [ ] 7. Skills and niche research
- [ ] 8. Import
- [ ] 9 to 14. Videos: queue, scripts, voice, media, editing, finishing, automation
