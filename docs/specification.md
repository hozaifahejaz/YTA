# YTA build specification

This tab is the single source of truth for building YTA. It consolidates every decision from the planning tab, resolves the places where that tab contradicts itself, and fills the gaps found in review. Where this tab and the planning tab differ, this tab wins.

Two markers are used throughout. **[VERIFY]** means a fact that was not confirmed against a live tool or official page and must be checked before the code that depends on it is written. **[OWNER]** means a decision only Huzaifa can make. Each has a default so the build is never blocked.

## 1. Product in one page

YTA is a native macOS app, for one person's own use, that runs faceless YouTube channels from idea to a finished upload folder. It does not upload. The owner uploads each video by hand.

For each channel the app can:

1. Research a niche (optional), or accept one typed in.
2. Produce a name, handle, brand kit, profile picture, banner and a copy-and-paste setup kit.
3. Keep the channel as one isolated folder holding every instruction for that channel.
4. Import an existing channel into the same folder shape.
5. Keep a queue of videos, research topics (optional), and write scripts that sound human and hold retention.
6. Generate narration through ai33pro.
7. Find legally usable media, assemble the video in Remotion, and render it.
8. Produce a finished video folder: the video file, a YouTube Kit Word file, and 3 to 5 thumbnails.

LLM work is done by command line tools the owner already has (Claude Code, Codex, OpenCode), run headless by the app.

## 2. Rules that are never broken

1. **Authorship.** Every commit, branch, pull request, issue, comment and release in `hozaifahejaz/YTA` is authored as `Huzaifa` with the GitHub no-reply address for `hozaifahejaz`. No co-author lines, no "generated with" lines, no AI tool named as author or contributor anywhere on GitHub, including the README and commit messages. Engine names inside the product (for example the `claude` command in an adapter, or "Claude Code" as a selectable engine in Settings) are product features and are allowed. **[OWNER]** confirm that reading.
2. **The LLM reasons, the app measures and renders.** Numbers come from data the app fetched. Images with text (profile picture, banner, thumbnail) are drawn by the app from a spec. Media links and licences come from the app's own searches. An LLM never supplies a statistic, a licence or a URL that the app has not fetched itself.
3. **A channel is a folder, and runs are locked to it.** No LLM run can read or write outside its channel folder. Only the app writes approved results into the folder.
4. **Voice is generated only in v4.** Never v2, never a silent fallback. See 8.3 for the open item.
5. **Secrets live only in the macOS Keychain.** Never in the repo, a channel folder, a log, a prompt, or an environment variable passed to an LLM tool.
6. **Claude Code runs on the subscription login.** The app never passes an Anthropic API key unless the owner switches that on in Settings.
7. **Every AI result is a draft** until approved, except where the channel's automation dial says otherwise (5.9).
8. **Light mode only.** Minimal, muted palette, one accent colour, real icons and logos, nothing cramped.
9. **A run never stops to ask a question.** It works inside a fixed tool list and anything outside the list is denied.

## 3. Technology and repository

### 3.1 Stack

| Area | Choice |
|---|---|
| Language and UI | Swift 6, SwiftUI, AppKit only where SwiftUI falls short (canvas, menu bar item) |
| Target | macOS 26 or later, Apple silicon only |
| Build | Swift Package Manager from the Command Line Tools. A script wraps the binary into `YTA.app` and signs it ad hoc. Xcode is not assumed. If a feature truly needs Xcode, stop and report it before working around it. **[VERIFY]** that a SwiftUI app with resources, an Info.plist and a menu bar item builds and runs this way on macOS 26. Do this first, in milestone 0. |
| Distribution | Built locally. Not sandboxed, not notarised, not on the App Store. No auto-update. |
| Storage | Plain files. No database, no server. |
| Video | Remotion (Node). Rendering and Studio are run as child processes. |
| Media tools | `ffmpeg` and `ffprobe` as shipped with Remotion (`npx remotion ffmpeg`, `npx remotion ffprobe`) so Homebrew is not required. **[VERIFY]** both subcommands exist in the pinned Remotion version; otherwise the health check offers to install ffmpeg. |
| Transcription | On-device, using Apple's Speech framework. **[VERIFY]** the macOS 26 API gives word-level timings; if not, use a bundled Whisper model through WhisperKit. |
| Word file | Written by the app with a small OOXML writer (a zip with `document.xml`). No Word, no Node dependency. |
| CI | GitHub Actions on a macOS runner: build, unit tests, lint. |

### 3.2 Repository layout

```
YTA/
├─ Package.swift
├─ Sources/
│  ├─ YTAApp/            app entry, windows, menu bar item
│  ├─ DesignSystem/      colours, type, spacing, icons, shared controls
│  ├─ Canvas/            node canvas, inspector host
│  ├─ Workflow/          node registry, run state machine, queue
│  ├─ Engines/           LLM tool adapters (Claude, Codex, OpenCode)
│  ├─ Skills/            built-in skills, discovery, review, install
│  ├─ ChannelStore/      folder reads and writes, path guard, history
│  ├─ YouTubeData/       Data API client, quota ledger, page fallback
│  ├─ BrandRenderer/     profile picture, banner, thumbnail drawing and checks
│  ├─ Voice/             ai33pro client, v4 lock, audio checks
│  ├─ Media/             source clients, licence ledger, downloader
│  ├─ Edit/              timeline builder, Remotion process control, render queue
│  ├─ Publish/           kit writer, credits page, final checks
│  ├─ Secrets/           Keychain wrapper
│  └─ Support/           logging, process runner, JSON schema validation
├─ Resources/            fonts, logos, built-in skills, prompt templates, banned-phrase list
├─ Remotion/             the Remotion project: compositions, shipped styles
├─ Tests/
├─ Scripts/              build-app.sh, sign.sh
└─ docs/                 this specification as Markdown
```

Each module depends only on `Support` and the modules it needs. `YTAApp` and `Canvas` never call an engine, a network client or the disk directly. They go through `Workflow`.

## 4. Files on disk

### 4.1 App data

```
~/Library/Application Support/YTA/
├─ settings.json         engines, per-step model defaults, plan, storage path, automation defaults
├─ tools.json            resolved paths and versions of each command line tool
├─ quota.json            YouTube API units used today (resets at midnight Pacific)
├─ templates/            saved custom nodes, channel templates, editing and thumbnail styles
├─ skills/               the app's own skills workspace
├─ remotion/             installed copy of the Remotion project with node_modules
└─ logs/
```

### 4.2 Channel folder

```
~/YouTube Automation/
├─ Channels/
│  └─ <Channel Name>/
│     ├─ channel.json        id, name, handle, format, language, country, status, engine choices, automation level
│     ├─ AGENTS.md           the instructions every LLM reads first
│     ├─ CLAUDE.md           one line importing AGENTS.md
│     ├─ profile/            niche.md, audience.md, voice.md, pillars.md, rules.md, sources.json
│     ├─ brand/              brand.json, avatar/, banner/, watermark.png
│     ├─ styles/             voice.json, editing.json, thumbnail.json, script.json, banned-phrases.txt, pronunciation.json
│     ├─ setup/              kit.md, checklist.json
│     ├─ research/           niche run, name checks, competitor snapshots, topic runs, competitors.json
│     ├─ workflow/           setup.json and video.json: the editable node lists for this channel
│     ├─ library/            music/, reference-scripts/, used-assets.json, used-phrases.json
│     ├─ queue.json          ordered list of video ids with status
│     ├─ calendar.json       planned and published dates, pasted video links, public stats snapshots
│     ├─ runs/               one folder per run: prompt, model, effort, usage, raw events, result
│     ├─ .history/           snapshots of instruction files for undo
│     ├─ .agents/skills/     skills that belong to this channel only
│     └─ videos/
│        └─ <Video Title>/   see 4.3
└─ Research/                 niche runs not yet tied to a channel, plus the watchlist
```

`profile/sources.json` lists which production sources the channel may use (stock footage, AI images, AI video, free online media, screenshots and snippets, AI voice) and the fair-use switch, which is off by default.

### 4.3 Video folder

The owner fixed what a finished video folder shows. Everything else goes inside `Working files`.

```
videos/<Video Title>/
├─ <Video Title>.mp4        the final rendered video
├─ YouTube Kit.docx         see 8.5
├─ Thumbnails/              3 to 5 variations, PNG
└─ Working files/
   ├─ video.json            stable id, title history, status per node, settings for this video
   ├─ brief.md, research-notes.md, sources.json, refined-prompt.md
   ├─ script.md             the approved script
   ├─ script.beats.json     the script as timed beats
   ├─ review.json           checks and reviewer scores
   ├─ audio/                one file per beat, narration.wav, timings.json
   ├─ shots.json            the shot list
   ├─ assets/               downloaded and generated media
   ├─ ledger.json           licence ledger
   ├─ timeline.json         what Remotion renders
   ├─ captions.srt
   ├─ credits.md            source for the credits page, plus its link once hosted
   ├─ qc.json               final video check results
   └─ render/               previews and intermediate renders
```

Rules for the folder name, which the planning tab did not cover:

- The folder name is the working title made safe for the file system: `/` and `:` replaced, trimmed to 120 characters, trailing dots and spaces removed.
- Identity is the `id` in `video.json`, never the folder name. `queue.json` refers to ids.
- When the final title is chosen, the app renames the folder and the `.mp4` to match and records the old name in `video.json`.
- Two videos with the same title get a numeric suffix.
- A copy of `captions.srt` is not placed at the top level by default. **[OWNER]** say if you want it beside the video for upload.

### 4.4 File rules

- Every JSON file carries `"schemaVersion"`. The store migrates older versions on load and never silently drops unknown fields.
- All writes are atomic: write a temporary file in the same folder, then rename.
- The app watches the channel folder and reloads on outside edits. An outside edit to an instruction file creates a history snapshot.
- JSON schemas for every file above live in `Resources/schemas/` and are used both for validation on load and as the `--json-schema` for LLM results.

## 5. Core systems

### 5.1 Node model

The canvas is a guided row of nodes that the owner can add to, remove from and edit. There is no free wiring.

A node has: `id`, `type`, `title`, `engine` (tool, model, effort) or none for app-only nodes, `promptTemplate` (editable), `inputs` (named files it reads), `outputs` (named files it writes), `approval` (always, by dial, never), and `state`.

- **Built-in node types** are registered in code. Each declares its inputs, outputs, checks and inspector view. Their prompt and engine can be edited. Their checks cannot be removed.
- **Custom node** = a prompt, an engine and one output file inside the channel folder. It may read any file in the channel or the current video.
- **Order and dependencies** come from inputs and outputs. Removing a node whose output another node needs shows which nodes break and asks for confirmation. Inserting a node places it after the last node that produces one of its inputs.
- **States:** waiting, running, needs you, done, failed, stale. Only "needs you" uses the accent colour. Redoing a done node marks every node downstream stale.
- **Templates:** any custom node, and any whole node list, can be saved to `templates/` and applied to another channel.
- Two node lists exist per channel: `workflow/setup.json` (run once per channel) and `workflow/video.json` (run once per video).

Default setup row for a new channel: Niche, Name, Brand, Profile picture, Banner, Voice, Editing style, Thumbnail style, Setup kit, Playbook.

Default setup row for an imported channel: Link, Snapshot, Analysis, Your input, Brand, Voice, Editing style, Thumbnail style, Playbook.

Default video row: Topic, Title, Brief, Research notes, Prompt, Script, Review, Voice, Shots, Media, Timeline, Cut review, Render, Final check, Thumbnails, Kit.

Voice, Editing style and Thumbnail style were missing from the setup row in the planning tab even though later decisions require them.

### 5.2 Run lifecycle

Every LLM step follows the same path.

1. `Workflow` builds the prompt from the node's template and the files named in its inputs.
2. The adapter starts the tool headless, with the channel folder as working directory, the chosen model and effort, a fixed tool list and a spend or turn cap.
3. The tool streams JSON events. The adapter maps them to plain progress lines for the activity strip and writes the raw stream to `runs/<run id>/events.jsonl`.
4. The final result must validate against the node's JSON schema. One repair attempt, then the node fails visibly.
5. The result is shown as a draft. On approval the app writes it through `ChannelStore`.
6. After the run, the app compares the folder before and after and flags any unexpected file.

State is saved after every stage, so a crash, a quit or a sleeping Mac resumes at the stage that was interrupted. The Mac is kept awake while a run or render is active. Stop is always available and keeps finished stages.

Runs continue when the window is closed. The app stays alive with a menu bar item showing what is running, and posts a notification when a node needs the owner.

### 5.3 Engine adapters

One protocol, three implementations at launch.

```
protocol EngineAdapter {
  func detect() async -> ToolStatus            // path, version, signed in or not
  func capabilities() -> EngineCapabilities    // schema output, effort, web search, skills folder, images
  func run(_ request: RunRequest) -> AsyncThrowingStream<RunEvent, Error>
  func cancel(runID: String)
}
```

| Tool | Headless command | Model and effort | Schema result | Skills folder |
|---|---|---|---|---|
| Claude Code | `claude -p --output-format stream-json` | `--model` alias, `--effort` | `--json-schema` | `.claude/skills` |
| Codex | `codex exec --json` | `-m`, `-c model_reasoning_effort=` | `--output-schema` | `.agents/skills` |
| OpenCode | **[VERIFY]** headless command, JSON output, model flag and schema support | | checked by the app if unsupported | **[VERIFY]** |

Requirements for every adapter:

- **Finding tools.** A Mac app does not inherit the terminal PATH. Ask the login shell once (`$SHELL -lc 'command -v claude'`) and store the result in `tools.json`. Re-check on launch.
- **Explicit flags.** Set every behaviour flag explicitly and record the tool version. On a version change, run a self-test prompt before any real run. Claude Code's documentation says a minimal mode that ignores the subscription login may become the default for headless runs, so the adapter must not depend on defaults. **[VERIFY]** current flag names against `claude --help` on the owner's Mac.
- **Clean environment.** Start the tool with a minimal environment. Remove every API key variable unless the owner switched API-key use on for that tool. Never pass ai33pro, YouTube or stock-site keys to an LLM tool.
- **Isolation flags.** Disable user-level instruction files, memory, personal skills and personal MCP servers for app-started runs, so only the channel's `AGENTS.md` and approved skills apply. **[VERIFY]** the exact flags per tool.
- **Permissions.** Fixed allow list per node type. Typical lists: reading files in the channel, web search and web fetch for research nodes, nothing else. Writing is allowed only into `runs/<run id>/scratch/`. Everything else is denied without a prompt (`--permission-mode dontAsk` on Claude Code **[VERIFY]**).
- **Limits.** A cap per run (`--max-budget-usd` or a turn limit). On a usage-limit or rate-limit message from a subscription tool, the adapter reports a typed error with the reset time if given, and the queue pauses that engine until then instead of failing the video.
- **Model names.** Use aliases (`haiku`, `sonnet`, `opus`) so new releases are picked up without an app change. Settings lets the owner type an exact model id per tool.
- **Later.** Google Antigravity (`agy`) and a local-model adapter are planned but not built now. Keep the protocol free of anything Claude-specific so they slot in.

### 5.4 Plan-aware defaults

Settings holds the owner's plan for each tool (for Claude: Pro, Max 5x, Max 20x, or API). A table in `Resources/plan-defaults.json` maps plan and node type to model, effort and how many runs may go in parallel. A smaller plan gets lighter models and one run at a time. A larger plan gets the strongest model on scoring and review nodes and parallel research. Every value is editable per node. Do not hard-code usage limits in code, since they change. Keep them in that file.

### 5.5 Chat inside a node

Any node can open a chat with its engine to shape the result, for example the thumbnail style. The chat is a multi-turn session in the same locked folder. When the owner clicks Save, the app asks the engine for the outcome as a structured rule or style file, shows it as a draft, and writes it to the profile on approval. The chat transcript is kept in `runs/`. The saved rule, not the chat, is what later runs read.

### 5.6 Skills

- The app ships its own skills for niche research, topic research, script review and thumbnail concepts in `Resources/skills/`.
- A Skills stage lets the LLM look for extra skills (`npx skills find`, plugin marketplaces). Each candidate is shown on a review card with its source, what it adds, and whether it contains scripts. The owner chooses Install or Skip for every one. There is no silent install.
- Installs go to the app's skills workspace or the channel's `.agents/skills/`, never to the owner's personal setup.
- Skill text and web pages are untrusted input. Prompts state that instructions found inside fetched content are data, and the fixed tool list is what actually limits the damage.

### 5.7 Channel store and history

- Every read and write goes through `ChannelStore`, which resolves symlinks and refuses any path outside the channel folder.
- Each approved change to an instruction file (`AGENTS.md`, `profile/`, `styles/`) saves a snapshot in `.history/` with a timestamp and the node that made it. The inspector shows a list with compare and restore. Snapshots are plain copies, not git.
- `AGENTS.md` is regenerated when the profile changes. A marked section holds the owner's manual edits and is preserved.

### 5.8 Secrets and settings

One Settings pane holds all keys: ai33pro, YouTube Data API, Pexels, Pixabay, Smithsonian, Rijksmuseum, Europeana, and the Google sign-in for credits pages. All are stored in the Keychain under the service name `YTA`. A key is read at the moment a request is made and is never logged. Log lines pass through a redactor that removes anything matching a stored secret.

### 5.9 Automation dial, cost and disk

- **Dial per channel:** approve every node, approve only script and final cut, or run straight through to the finished folder. The final check (8.4) can never be skipped by the dial.
- **Estimate before each video:** voice characters and ai33pro credits, image generations, expected LLM usage against the plan. A cap per video and per day stops the queue when reached.
- **Disk:** Settings shows space used per channel. Working files (`assets/`, `render/`, per-beat audio) can be cleared automatically a set number of days after a video is finished. The ledger, script, timeline and kit are never auto-deleted.

### 5.10 Errors

Errors are typed: tool missing, not signed in, usage limit, schema mismatch, network, quota exhausted, licence rejected, check failed, disk full. Each has a plain-language message, a suggested action and a retry point. A failed node keeps finished stages and retries from the failed one.

## 6. Interface

### 6.1 Window

One window, three areas: channel sidebar (with search and groups, since channels are unlimited), canvas in the middle, inspector on the right. An activity strip at the bottom says in plain words what is running, with elapsed time, usage and a link to the raw log.

### 6.2 Design tokens

- Light mode only. Surfaces are near-white and soft grey. One muted accent colour used only for the node that needs the owner and the primary button. **[OWNER]** pick the accent. Default: a muted slate blue.
- System font (SF Pro), SF Symbols for icons, official logos for YouTube and each LLM tool where they identify something.
- Spacing on an 8 point grid. Generous padding. One primary action per screen. No gradients, glows, emoji or decorative icons. No nested panels or tabs inside tabs.
- Liquid Glass comes from standard macOS 26 controls. Do not imitate it with custom drawing.
- Every colour pair used for text meets a 4.5 to 1 contrast ratio. All controls have accessibility labels and work from the keyboard.

### 6.3 Canvas

- Setup row at the top. Below it, one row per video in progress, newest first, collapsible.
- A node shows its title, state, a one-line result when done, and the logo of the engine that produced it.
- Clicking a node opens it in the inspector. A plus button between nodes inserts a node. A node's menu has Edit prompt, Change engine, Redo, Remove, Save as template.
- Keyboard: ⌘N new channel, ⌘K command palette, ⌘1 to ⌘9 jump to a node, ⌘. stop a run.

### 6.4 Screens

First run and health check, Channels sidebar, New channel ("Find me a niche" or "I have a niche"), Import channel, Canvas, one inspector per built-in node type, Queue, Research (runs not tied to a channel, and the watchlist), Calendar, Render queue, Templates, Settings (Engines and plan, Keys, Skills, Storage and disk, Automation defaults, Banned phrases).

The first-run health check looks for each LLM tool and its sign-in, Node, the Remotion install, ffmpeg and free disk space, and offers a fix for each missing item.

## 7. Channel setup (phase 1)

### 7.1 Niche research (optional)

Seven stages. The owner picks Quick, Standard or Deep on every run.

| # | Stage | Done by | What happens |
|---|---|---|---|
| 1 | Brief | Owner | Interests, format, language, target countries, topics to avoid, depth |
| 2 | Skills | LLM, owner approves | Proposes extra research skills |
| 3 | Discover | LLM with web search | 25 to 40 candidates, screened to 12 |
| 4 | Measure | App | Real YouTube numbers per candidate |
| 5 | Score | LLM, strongest model | Rubric scores with cited evidence |
| 6 | Challenge | A different model | Argues against the top picks. Skipped in Quick. |
| 7 | Shortlist | Owner | 3 to 5 niche cards |

- **Ranking goal:** ad revenue, aimed at countries with high ad rates. Rubric dimensions: demand, competition, earning potential, production fit, durability, policy risk, personal fit. Balanced weights by default, editable per run.
- **Measures computed by the app:** median views of recent videos, share of strong videos from channels under 50,000 subscribers, number of active channels and top-three dominance, channels under a year old past 10,000 subscribers, typical length and Shorts mix.
- **Quota:** 100 `search.list` calls a day and 10,000 units a day. A Standard run budgets about 30 searches. The app shows remaining quota before a run and refuses to start one it cannot finish. **[VERIFY]** current quota costs.
- **Policy risk:** YouTube does not monetise templated, mass-produced or repetitive content. A niche that only works that way scores badly.
- **Card contents:** niche and angle in one line, seven scores, three example channels, three outlier videos, an earnings range marked as an estimate, five video ideas, the main risk. Choosing a card creates the channel. Runners-up go to the watchlist.

### 7.2 YouTube data

- Primary: YouTube Data API v3 with the owner's key. `channels.list` with `forHandle` costs 1 unit.
- Fallback when there is no key or quota is exhausted: an offscreen `WKWebView` inside the app loads public YouTube pages and reads the page's embedded data. It is slow, rate-limited to one page every few seconds, and results are labelled lower confidence. The planning tab named a headless browser without saying which. This is the choice.
- The quota ledger is persisted and resets at midnight Pacific time.

### 7.3 Name and handle

1. The LLM writes 30 to 40 names: English, made-up words allowed, one or two words, 15 characters or fewer where possible, easy to say and spell, no digits or hyphens.
2. The app checks each handle on YouTube (1 unit each).
3. For the best 10, the app searches for same-name or near-same-name channels and reads their size and last upload.
4. Labels: Clear, Small overlap (under 1,000 subscribers and no upload in a year), Taken (dropped). Thresholds editable.
5. Extra information per name: the `.com` domain through RDAP, and the same handle on Instagram, TikTok and X. Social checks from public pages are unreliable, so they are shown as "looks free" or "looks taken", never as fact.
6. The owner sees 6 to 8 name cards and picks one or asks for another round with a note.

The kit always carries two fallback handles, since a handle is only confirmed when claimed. Add a link to a trademark search for the chosen name. The app does not judge trademarks.

### 7.4 Brand, profile picture and banner

- **Brand node:** the LLM proposes three directions, each a spec of 3 or 4 colours with checked contrast, a typeface from the bundled open-licence fonts, and a mark style. The app renders three boards. The pick is saved as `brand/brand.json`. Bundle 12 to 16 fonts under the SIL Open Font License and ship their licence files.
- **Profile picture:** text-based by default. The app draws 6 to 9 variants and centres the visible ink of the glyphs, not the line box. Everything stays inside the middle 70% of the frame. Previews as circles at channel-page, watch-page and comment size. Export 800 × 800 PNG. A picture-based option uses an image route (below), removes the background and fits the symbol into the same safe circle.
- **Banner:** composed in layers by the app, 2560 × 1440. Name and tagline by default, every line editable, schedule line optional. All text sits inside the 1546 × 423 safe area with 48 px inner padding. Typographic background by default, AI background as an option, never with text in it. A device switcher shows TV, desktop, tablet and phone crops. Checks before export: text inside the safe area, contrast at least 4.5 to 1, smallest text at least 56 px tall, exact size, under 6 MB. **[VERIFY]** the tablet crop width against a real upload.
- **Image routes** (one setting): ChatGPT through Codex, ai33pro image generation (`/v1i/task/generate-image`), or the LLM writing drawing code that the app renders. App-drawn text and patterns remain the default.
- **Watermark:** a square mark from the profile picture, at least 150 × 150, under 1 MB.

### 7.5 Voice, editing style and thumbnail style nodes

- **Voice:** see 8.3. The owner picks from a few samples that suit the channel. Saved to `styles/voice.json`.
- **Editing style:** the owner picks a shipped style or shapes one in chat: captions on or off and their look, music on or off and its level, transitions, motion graphics style, colour look (LUT), audio settings, resolution (1080p, 1440p or 4K), filler for empty shots (AI image, text card or ask). Saved to `styles/editing.json`.
- **Thumbnail style:** shaped through chat with the LLM, then saved to `styles/thumbnail.json`: layout, type treatment, colour use, image treatment, number of words.

### 7.6 Setup kit

A checklist where each line has a copy button, a link to the right YouTube Studio page and a tick box: name, handle and fallbacks, description with the hook in the first 150 characters, keywords, country, language, upload defaults, "made for kids" answer with reason, when the AI-content label applies, home layout and starter playlists, phone and 2-step verification, watermark, monetisation targets with a link to the live Partner Program page. Everything is copy and paste. The app does not write to YouTube.

### 7.7 Playbook

Drafts `voice.md`, `pillars.md` and `rules.md` from the niche, audience, name and brand. The owner reviews each file. When the fair-use switch is on, `rules.md` states that such media needs commentary or transformation.

### 7.8 Import an existing channel

1. **Link.** A handle, channel URL or video URL resolves to the channel.
2. **Snapshot.** Public record: identity, description, keywords, totals, images, playlists, and every upload with title, description, tags, length, views, likes and date. Dated and kept. A Refresh button takes a new one.
3. **Analysis.** The LLM drafts the profile: niche, audience, pillars, title patterns, upload rhythm, and the videos that beat the channel's own median with what they share. It reads thumbnails and public transcripts for a sample of top videos.
4. **Your input.** A short interview beside the drafted profile.
5. **Brand.** Existing images saved, colours extracted, banner run through the safe-area check. Redesign optional.
6. Then Voice, Editing style, Thumbnail style and Playbook as for a new channel.

Owner-only numbers (retention, click-through, revenue) are out of scope. **[OWNER]** an import test channel link is still needed to build against.

## 8. Making a video (phases 2 to 5)

### 8.1 Queue and topics

- Each channel has a queue. A row is a video with title, script state and status.
- Add a video three ways: title plus the owner's own script, title only, or a topic from research. Bulk add from a pasted list or a file. Accepted files: `.txt`, `.md`, `.docx` for a script, `.csv` for a list of titles.
- The queue runs one video at a time, top to bottom. Rows can be reordered, paused or skipped. Different channels can run at once within the plan's parallel limit. Only one render runs at a time across the whole app.
- The owner's own script is never changed. A check can be run on request.

Topic research (optional) has seven stages: Skills (LLM, owner approves), Collect (app pulls recent uploads from `research/competitors.json` and niche searches), Find outliers (app marks videos far above their own channel's median), Widen (LLM adds rising topics from web search), Score (LLM ranks on demand, fit, freshness and crowding, and drops topics the channel already covered), Titles (LLM writes five titles per topic), Pick (owner). It returns 10 topics with five titles each. The competitor list is seeded by niche research or import.

### 8.2 Script pipeline

1. **Brief.** Title, target length, per-video guidelines, plus the channel's `voice.md`, `rules.md` and `styles/script.json`.
2. **Research notes.** For factual topics an LLM with web search gathers facts with sources into `research-notes.md` and `sources.json`. Can be switched off. The source list is kept as the fact trail.
3. **Prompt refinement.** Claude turns the brief into one precise prompt written for the chosen writer. The owner can read and edit it before it is sent.
4. **Writing.** ChatGPT through Codex by default. The writer can be changed per channel or per video.
5. **Checks.** The app measures length and scans for banned phrases. A second model that is never the writer reviews for retention and for sounding human.
6. **Revision.** Failed checks go back to the writer with exact notes, at most two rounds.
7. **Approval.** The owner reads, edits and approves, unless the dial says otherwise.

Script rules the prompts and the reviewer enforce:

- **Sounding human.** Casual spoken style, contractions, mixed sentence lengths, direct address. No stock openers, no announcing what the video will do, no summary that repeats what was just said, no empty rhetoric. Any sentence that can be cut without loss is flagged.
- **Banned list.** A starter list ships in `Resources/`, editable globally and per channel, and per language.
- **Reference scripts.** A channel can hold a few samples in `library/reference-scripts/` that set the style to match.
- **Retention.** The first 15 seconds deliver on the title with no greeting. Questions are opened early and paid off later, with a new one opened before each payoff. Something changes every 30 to 60 seconds. The ending stops when the value stops and points to the next video.
- **Beats.** The script is stored as timed beats in `script.beats.json`. The reviewer scores each beat, giving a retention map.
- **Length.** Set in minutes or words, per video or as a channel default. Minutes convert at the channel's speaking rate, 150 words a minute by default, with 5% tolerance. Shorts have their own preset. The rate is per channel because it varies by language and voice, and it is recalibrated from real narration after the first video.
- **Repetition.** After approval, distinctive openings and phrases are added to `library/used-phrases.json`, and the reviewer flags reuse across the channel's videos.

### 8.3 Voice

ai33pro API, as read from its API page on 17 November:

- Header `xi-api-key`.
- `POST https://api.ai33.pro/v3/text-to-speech` as form data: `text` (up to 1,000,000 characters), `voice_id` with a provider prefix (`elevenlabs_`, `minimax_`, `clone_`, `edge_`, `kokoro_`, `vbee_`, `fishaudio_`), `speed` 0.5 to 1.5, `with_transcript`, `file_name`, `pronunciation_dictionary_id`. Returns `task_id`.
- Poll `GET /v1/task/<id>` until done, then download the audio at once, since result links may expire. Do not use the webhook option, because the app has no public address.
- `GET /v3/voices?provider=...` with filters for language, gender, age, accent, category and use case, each voice with a `preview_url`.
- `GET /v1/credits` for the balance.

**The v4 lock is unresolved and blocks only this node.** The speech call has no model or version field, and the app's own Text to Speech screen shows only a voice, a speed, and High quality or Low cost. The owner reports that his other chats generate "in V4" and that the default is "v2". **[OWNER]** say where V2 and V4 appear. Until then, build the lock as a seam:

- A single constant, `VoiceLock`, defines what makes a request v4: a required field and value, a required voice id pattern, or both.
- Every outgoing speech request passes through one function that refuses to send unless `VoiceLock` is satisfied, and checks the task result for the same marker if the service reports one.
- While `VoiceLock` is undefined, the Voice node is disabled with the message "Voice is locked until v4 is confirmed". There is no setting, prompt or fallback that bypasses it.
- A unit test asserts that a request without the v4 marker never reaches the network layer.

Voice pipeline:

1. **Voice per channel.** At setup the app filters the voice list by the channel's language and tone, plays a few previews, and the owner picks. Saved as the channel default and changeable later.
2. **Prepare.** Spoken text is separated from visual notes. Numbers, abbreviations and names are rewritten for speech using `styles/pronunciation.json`.
3. **Estimate.** Character count and credits shown before anything is generated.
4. **Generate by beat.** One request per beat, so changing a sentence regenerates one beat. A few beats may run in parallel. **[VERIFY]** ai33pro rate limits.
5. **Check.** The app transcribes each beat on the Mac and compares it with the script to catch skipped or mangled words. It trims long silences and normalises loudness.
6. **Timings.** Word-level timings saved to `timings.json`. Captions and shots are synced to them.
7. **Approve.** The owner listens, redoes any beat, and approves.

### 8.4 Visuals, editing and rendering

**Shot list.** An LLM splits each beat into shots a few seconds long: what the viewer should see, search terms, preferred kind (archive footage, photo, map, text card, screenshot, AI image, AI video).

**Finding media.** The app runs every search, so each result has a real link and licence.

| Order | Source | Access |
|---|---|---|
| 1 | Wikimedia Commons | Public API, no key, descriptive User-Agent required |
| 1 | Internet Archive | Public search and metadata API, no key |
| 2 | The Met, Library of Congress, NASA | Public APIs, no key |
| 2 | Smithsonian, Rijksmuseum, Europeana | Free API keys |
| 3 | Pexels, Pixabay | Free API keys |
| 4 | Generated | AI images through the image routes, screenshots through an offscreen web view |
| 5 | Fair-use media | Only when the channel's switch is on |

The order and which sources are on are per channel. **[VERIFY]** each API's current terms, rate limits and licence fields before writing its client. AI video has no provider chosen. **[OWNER]** name one, or it stays off.

**Licence ledger.** Every asset is recorded in `ledger.json` with source page, direct link, author, licence, licence link, whether credit is required, retrieval date and a hash of the file. Accepted by default: public domain, CC0, CC BY, CC BY-SA, and the Pexels and Pixabay licences (recorded under their own names, since they are not Creative Commons). Non-commercial and no-derivatives licences are rejected. An asset with an unreadable licence is rejected, not guessed. CC BY-SA carries a share-alike condition, so the ledger marks those assets and the channel can switch that licence off.

**Choosing.** A vision-capable LLM ranks candidates for each shot against the line being spoken. The app rejects media that is too small for the chosen resolution, too short, or watermarked. Used assets are recorded in `library/used-assets.json` and reuse across videos is limited. A shot with no good result uses the channel's filler setting.

**Review board.** One row per shot with the chosen asset and alternatives to swap in. A channel can skip the board through the dial.

**Music.** Tracks come only from `library/music/`, which the owner fills and approves. Each track has a ledger entry. ai33pro music generation can add tracks to the library as an option. Music is lowered under the voice automatically.

**Timeline and Remotion.**

- The app writes `timeline.json`: every shot, asset, caption and audio cue with exact timings from the narration.
- The Remotion project in `Remotion/` has one composition per aspect ratio (16:9 and 9:16) that takes the timeline and the channel's editing style as input props. Shipped editing styles and motion graphics styles are components selected by name. A custom style is a new component the owner can ask an LLM to write, saved to `templates/`.
- On first run the app installs the project into Application Support with a lockfile. Remotion downloads its own headless browser on first render, so the health check triggers that early.
- Still images get slow movement, and the edit varies its patterns so videos do not look templated.
- **Cut review.** The app opens Remotion Studio on the video's timeline for the owner to scrub and review before the final render. Shot changes are made on the review board in the app and Studio reloads. **[VERIFY]** whether prop edits made in Studio can be saved back to `timeline.json`. If not, Studio is view-only and the app says so.
- **Rendering.** A queue on the Mac, one render at a time, pause and resume, optional overnight start. Previews render at reduced resolution. Final renders at the chosen resolution. Concurrency is kept low for a fanless MacBook Air.
- Remotion is free for individuals and companies of up to three people. **[VERIFY]** the current licence terms.

**Shorts from long-form** (optional per channel). An LLM picks 1 to 3 self-contained stretches from the retention map. The app builds a 9:16 timeline for each from the same assets and audio. Each Short gets its own video folder linked to the parent.

**Final check.** After rendering the app checks for black or frozen frames, missing audio, audio and caption drift against the timings, loudness (target −14 LUFS integrated, true peak at or below −1 dBTP), length against the target, resolution and frame rate. Results go to `qc.json`. A failed check blocks the video from being marked finished.

### 8.5 Thumbnails, kit and finishing

**Thumbnails.** An LLM proposes 3 to 5 concepts from the title and hook, each a different angle. The app composes each from `styles/thumbnail.json`: a background from the video's assets or an image route, plus a few words set by the app. The text adds to the title and never repeats it. Previews at phone-feed and desktop-sidebar size beside recent competitor thumbnails. Checks: readable at phone size, strong contrast, bottom-right corner clear for the duration label, 1280 × 720 or larger at 16:9, under the upload size limit. **[VERIFY]** the current limit. Output is 3 to 5 PNG files in `Thumbnails/`.

**YouTube Kit.docx** contains, in this order:

1. 10 title ideas, the recommended one first, each within 100 characters with the key words in the first 60.
2. Description: a two-line opening, chapters from the timed beats (first chapter at 0:00, at least three chapters, each at least 10 seconds), the credits link, the channel footer.
3. Tags within YouTube's 500-character total, and up to three hashtags.
4. Upload settings: category, language, playlist, "made for kids" answer, whether the AI-content label must be ticked (derived from the ledger), comment setting.
5. A pinned comment draft and end screen suggestions.
6. Which thumbnail goes with which title, for YouTube's own thumbnail test.
7. An upload checklist and the suggested publish slot.

**Credits page.** One Google Doc per video listing every asset with author, licence and source. Its link goes in the description. The planning tab did not say how the Doc is created. The choice:

- With a Google sign-in (OAuth through the owner's Google Cloud project, the `drive.file` scope only), the app creates the Doc, sets it to "anyone with the link can view", and stores the link.
- Without a sign-in, the app writes `credits.md` and a `Credits.docx` in `Working files`, and the kit shows a placeholder with a one-line instruction to upload it to Google Docs and paste the link back.
- **[VERIFY]** the consent-screen requirements for a personal-use OAuth app. **[OWNER]** choose sign-in or manual. Default: manual first, sign-in added after.

**Final gate.** A video is marked finished only when every asset has a ledger entry, the credits link exists or is flagged as pending, the final check passed, and a review against YouTube's reused and templated content rules passed.

**Calendar and learning loop.** Each channel has a calendar that suggests the next slot from its cadence. When the owner pastes the published video's link, the video is marked published and the app follows its public views, likes and comments at set intervals. Those numbers feed topic scoring and title writing for that channel. Owner-only analytics are out of scope.

## 9. What the review found

Contradictions in the planning tab, with the ruling that applies:

| Planning tab says | Ruling |
|---|---|
| Canvas is fixed and nodes cannot be deleted | Nodes can be added, removed and edited (5.1) |
| Engines include Gemini and Grok | Claude Code, Codex and OpenCode. Antigravity later. Grok dropped. |
| Light and dark mode | Light mode only |
| Built with Xcode 27 | Swift Package Manager without Xcode |
| Video folders named `videos/001-title/` with `audio/`, `render/`, `publish/` | `videos/<Video Title>/` as in 4.3 |
| Credits added to the description | A Google Doc per video, linked from the description |
| Kit as `kit.md` in the publish pack | `YouTube Kit.docx` for each video. `setup/kit.md` remains for channel setup only. |
| API upload discussed | No upload. The owner uploads by hand. |
| Nine-milestone and thin-path build orders | Whole app built in the order in section 11 |
| "Phase 2 not discussed until Phase 1 is polished" | Superseded. All phases are planned and built together. |
| Voice model is "Eleven v4" by assumption | Unknown. See 8.3. |

Gaps that had no answer in the planning tab, and where this tab answers them:

1. Voice, editing style and thumbnail style had no place in channel setup (5.1, 7.5).
2. Video folder naming when titles change, clash or contain illegal characters (4.3).
3. How the credits Google Doc is created and shared (8.5).
4. Which headless browser is the YouTube fallback (7.2).
5. How the Word file is written without Word (3.1).
6. Which transcription engine checks narration and gives word timings (3.1).
7. Where music comes from (8.4).
8. How Shorts are cut from long-form (8.4).
9. Which media source APIs are used and which need keys (8.4).
10. Pexels and Pixabay licences are not Creative Commons and need their own ledger category (8.4).
11. App-level data outside channel folders, schema versions and atomic writes (4.1, 4.4).
12. Behaviour on subscription usage limits (5.3).
13. Keeping keys out of LLM tool environments, and treating fetched content and skills as untrusted (5.3, 5.6).
14. How chat inside a node becomes a saved rule (5.5).
15. How the automation dial squares with "every result is a draft" (2, 5.9).
16. Where ffmpeg comes from when Homebrew is not assumed (3.1).
17. Speaking rate per language and voice (8.2).
18. Trademark and social-handle checks are advisory only (7.3).
19. Loudness targets and concrete final-check thresholds (8.4).
20. Testing, CI and a definition of done (11, 12).

## 10. Open items

**[OWNER]** decisions, each with the default the build uses until answered:

| # | Question | Default |
|---|---|---|
| 1 | Where do V2 and V4 appear in ai33pro? | Voice node stays locked |
| 2 | Are engine names inside the product acceptable under the "no mention" rule? | Yes. The rule covers authorship and attribution. |
| 3 | Credits page by Google sign-in or manual upload? | Manual first |
| 4 | AI video provider? | Off |
| 5 | Accent colour? | Muted slate blue |
| 6 | Captions file beside the video at the top level? | No, in Working files |
| 7 | Import test channel link? | Build against any public channel |
| 8 | Is Xcode installed after all? | Assume not |

**[VERIFY]** before writing the code that depends on each:

1. SwiftUI app builds and runs from Swift Package Manager alone on macOS 26, including resources and a menu bar item.
2. Current headless flags for Claude Code, Codex and OpenCode on the owner's Mac: output format, schema output, model and effort, permission mode, flags that disable personal settings, spend or turn caps.
3. Whether Claude Code's headless mode still uses the subscription login by default.
4. YouTube Data API quota costs, and the page fallback against live pages.
5. Banner tablet crop and thumbnail size limit against real uploads.
6. Apple Speech word timings on macOS 26.
7. Remotion: pinned version, licence terms, `ffmpeg` and `ffprobe` subcommands, saving props from Studio.
8. Each media source API: terms, rate limits, licence fields.
9. ai33pro: rate limits, result link lifetime, audio format, how High quality and Low cost are chosen through the API.
10. Google OAuth requirements for a personal-use app creating Docs.
11. YouTube Partner Program thresholds, which change on 1 February 2027.

## 11. Build sequence

The whole app is built before first release, in dependency order. Every milestone ends with the app building on the macOS runner, its tests passing, and its acceptance check met. Do not start a milestone until the previous one passes.

| # | Milestone | Acceptance check |
|---|---|---|
| 0 | Proof of build: Swift package, app bundle script, ad hoc signing, CI | An empty window opens on the owner's Mac from a CI-built or locally built app |
| 1 | Foundation: design system, window, sidebar, canvas, inspector host, Settings, Keychain, health check, storage folder | Create an empty channel and see its default row. Health check lists every tool. |
| 2 | Channel store: folder layout, schemas, path guard, atomic writes, folder watching, history | A write outside the channel is refused in a test. An instruction edit can be restored. |
| 3 | Workflow engine: node registry, states, dependencies, add, remove and edit nodes, templates, run state machine, crash resume, menu bar item, notifications | Kill the app mid-run and it resumes at the interrupted stage |
| 4 | Engines: Claude Code, then Codex, then OpenCode. Activity strip, run logs, schema validation, limits, plan defaults, chat in a node | The same test node returns a valid result from each tool inside a channel, with no file touched outside it |
| 5 | YouTube data: API client, quota ledger, page fallback | Handle check and channel snapshot work with and without a key |
| 6 | Naming, brand, profile picture, banner, setup kit, playbook | A channel goes from a typed niche to exported images that pass every check |
| 7 | Skills and niche research | A Standard run returns a shortlist where every number traces to fetched data |
| 8 | Import | A public channel becomes a complete profile folder |
| 9 | Queue, topic research, script pipeline | A queued title becomes an approved script within 5% of target length with no banned phrase |
| 10 | Voice: ai33pro client, the v4 lock seam, voice pick, per-beat generation, checks, timings | With the lock undefined the node refuses to run. With it defined, a script becomes narration with word timings. |
| 11 | Media: source clients, ledger, ranking, review board, music library | Every chosen asset has a complete ledger entry. A non-commercial asset is rejected in a test. |
| 12 | Editing: timeline, Remotion project, shipped styles, Studio review, render queue, final check, optional Shorts | A full video renders at 1080p and passes the final check |
| 13 | Finishing: thumbnail style chat, thumbnails, kit Word file, credits page, final gate, calendar, learning loop | The finished folder holds exactly the video, the kit and the Thumbnails folder, plus Working files |
| 14 | Automation dial, cost caps, disk controls, polish pass, accessibility pass | One video runs straight through unattended on a test channel |

## 12. Testing

- **Unit tests** for the path guard, schema migration, the quota ledger, minutes-to-words, the banned-phrase scan, safe-area and contrast checks, licence acceptance rules, the v4 lock, the kit writer, and folder naming.
- **Adapter tests** against recorded event streams from each tool, so CI does not need a signed-in tool. A manual smoke test with real tools runs on the owner's Mac per release.
- **Snapshot tests** for rendered profile pictures, banners and thumbnails at each device crop.
- **Network clients** tested against recorded responses. No test calls a paid service.
- **One end-to-end test** on a fixture channel with stub engines, from typed niche to finished folder.
- CI runs build, tests and a Swift formatter check on every push. The owner's Mac is needed only for the real-tool smoke test, Remotion renders and the final look of the app.

## 13. Definition of done

The app is finished when, on the owner's MacBook Air with nothing but the Command Line Tools, Node and the three LLM tools installed:

1. A new channel can be taken from niche research to exported brand files and a complete setup kit.
2. An existing channel can be imported into the same folder shape.
3. A queued title becomes a finished folder holding the video, `YouTube Kit.docx` and 3 to 5 thumbnails, with every asset in the licence ledger.
4. No voice is ever generated outside v4, proven by a test.
5. Two channels can run at once and neither folder gains a file from the other.
6. Quitting, crashing or sleeping mid-run loses no finished work.
7. No secret appears in the repo, a channel folder or a log.
8. Nothing on GitHub names an AI tool as author or contributor.
