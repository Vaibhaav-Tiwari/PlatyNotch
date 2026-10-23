# PlatyNotch: design

Status: approved direction, 2026-10-23. "PlatyNotch" is a working name; the bundle id `dev.platynotch.app` and module paths `github.com/platynotch/...` are placeholders to replace before the first release.

## What it is

A free, open-source (Apache-2.0) MacBook notch app that does three jobs:

1. **Agent hub.** Every Claude Code, Codex, Gemini, Cursor and OpenCode session gets a live state in the notch (active, idle, waiting for input, blocked, exited). When Claude Code asks permission, the exact command appears in the notch with Allow and Deny.
2. **Your day.** Everything both researched apps ship as standard, built as widgets:
   - Time: several timers, stopwatch with laps, alarms, world clocks, focus sessions (25/50/90/custom).
   - Music: now playing from any app, artwork glow, scrubbing, live visualiser from system audio.
   - System: volume, brightness and keyboard-backlight HUDs; battery and charging; AirPods battery; downloads; keep-awake.
   - Files: a shelf you drop files onto (drag out, AirDrop, Quick Look); clipboard history with a ⌥⇧V picker.
   - Day: next meeting with Join and 10/5/1-minute countdowns, reminders with quick add ("call Priya at 5pm"), weather (Open-Meteo), open loops.
   - Wellbeing: water, stand and 20-20-20 eye-break nudges that stay quiet during focus, meetings and full screen.
   - Fun and launch: Snake, Tetris, 2048, Flappy; pinned sites; Shortcuts.
   - Appearance: Always on or Minimal, open on hover or click, pill width, live side, displays, spring tuning; under 1% CPU at rest.
3. **Personal memory (opt-in).** On-screen text read through the Accessibility API is stored locally, searchable, exposed to any MCP client, and mined for open loops (commitments and action items).
4. **Power features (each off by default).** Droppy's floating baskets with shake-to-summon, file actions (convert, compress, zip, OCR, remove background, batch rename), Quickshare links, screen capture with annotation, window snapping, menu bar manager, lock-screen view and camera mirror; Crowny's notes/Obsidian tasks, GitHub, Home Assistant, Apple Mail, voice dictation and assistant.
5. **Platy the platypus.** The mascot: like the platypus, which has a bit of every animal, PlatyNotch has a bit of every notch app. Original vector art drawn in code; moods follow what is live (working, waiting on you, done, dancing to music, focused, sleepy). Also the app icon and menu bar icon. Ships in v0.1 (Plan 3b Task 13). Notification mirroring is decided by a spike first.

A separate paid edition, PlatyNotch Pro, builds on this core through the extension points below and lives in its own private repo. Nothing in this repo may depend on Pro.

## Research it rests on

- Crowny (closed, Swift): hooks into agent configs, a Unix-socket approval helper, MediaRemote via `/usr/bin/perl`, usage via the Claude status line.
- Droppy (GPL-3.0 + Commons Clause): notch panel tricks, drag-pasteboard polling. Ideas only, no code.
- agent-orchestrator (Apache-2.0): 50 agent adapters, event→state mapping, merge-safe hook installers. **Code is ported** with attribution. See `docs/research/agent-integrations.md`.
- minimi (closed, Electron): thread → hourly version → derivative memory model, sqlite-vec, open loops with resolution evidence, MCP. Ideas only.

## Architecture

```
agent CLIs ──hook──▶ notch hook <agent> <event> ─┐
Claude statusLine ──▶ notch statusline ─▶ usage.json
                                                 │ Unix socket, NDJSON (protocol v1)
Mac app (Swift) ◀──── subscribe/decide ────▶  notch serve  (Go core)
  ├ notch panel, widgets                         ├ session store (AO state machine)
  ├ capture (AX text) ── capture.text ──────▶    ├ approvals + policy
  └ plugins (Pro adds one)                       ├ usage watcher, transcript discovery
                                                 ├ memory engine (SQLite, FTS5, vectors)
Claude Desktop / Code / Cursor ──stdio──▶ notch mcp   (reads memory.db read-only)
                                                 └ extensions (Pro registers here)
```

- **Go core** (`core/`), one binary `notch`, holds all logic so it is testable without a GUI and portable to Windows/Linux later.
- **Swift app** (`apps/mac/`) is the UI, capture and macOS integration only. It launches `notch serve` from its bundle and keeps `~/Library/Application Support/PlatyNotch/bin/notch` symlinked to it; agent configs reference that stable path.
- **Protocol** (`core/protocol`, `docs/PROTOCOL.md`): one JSON object per line over `~/Library/Application Support/PlatyNotch/notch.sock`, mode 0600, peer uid checked.

## Rules that hold everywhere

- A hook never breaks an agent: any failure → empty stdout, exit 0, so the agent falls back to its own terminal prompt. A hook never approves on failure.
- If no UI or decider is connected, a permission hook returns immediately (no wait).
- Approvals show the exact command or path, never a paraphrase.
- An approval is answered at most once; later answers get "already resolved".
- User hook entries and unrelated settings in agent config files are preserved; the first modification writes `<file>.platynotch-backup`.
- Memory is off by default. Password managers are excluded by default; secure input mode is never captured; obvious secrets are redacted before storage.
- The free edition sends nothing anywhere unless the user turns on something that is network by nature: an AI provider (Ollama or an OpenAI-compatible key), weather (Open-Meteo), pinned-site favicons, Quickshare, GitHub, Home Assistant, Sparkle update checks. No telemetry.
- Every feature is a widget or controller that can be disabled; disabled features do no work.

## Extension points (the contract Pro builds on)

Go (`core/ext`): `Extension` with `Start(ctx, Host)`; `Host` gives snapshot, subscribe, decide, memory, config, policy providers, auditors, decider registration and `ext.event` emission. Optional `RequestHandler` receives `ext.request` messages from the UI.
Go (`core/memory/provider`): `RegisterEmbedder` and `RegisterExtractor` by name.
Go (`core/cli`): `Run(ctx, args, opts...)` with `WithEdition`, `WithExtensions`, `WithCommands`, so Pro ships its own binary `notch-pro` built from the same CLI.
Swift (`PlatyNotchUI`): `NotchPlugin` protocol (settings sections, panel tabs, ext events, URL handlers), `NotchWidget` protocol registered through `PluginContext.register(widget:)`, and `NotchApp.run(coreBinary:plugins:)`, so Pro ships its own app target built from the same package and can add widgets.

## Out of scope for the free edition

Remote/phone approvals, hosted AI, cross-device sync, remote MCP connector, Teams policy/audit. These are Pro.

## Plans

1. `docs/superpowers/plans/2026-10-23-01-core-agenthub.md`
2. `docs/superpowers/plans/2026-10-23-02-memory.md`
3. `docs/superpowers/plans/2026-10-23-03-mac-app.md`
3b. `docs/superpowers/plans/2026-10-23-03b-everyday-widgets.md`
3c. `docs/superpowers/plans/2026-10-23-03c-power-features.md`

Order: 1 → 3 (Tasks 1–6, 10) → 3b Task 1 → the rest of 3, 3b and 2 in parallel → 3c.
- **v0.1** ships after Plans 1, 2, 3 and 3b.
- **v0.2** ships after Plan 3c.

Pro plans (4–6) live in the Pro repo and start after v0.1.
