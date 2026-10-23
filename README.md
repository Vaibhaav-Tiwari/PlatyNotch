# PlatyNotch

PlatyNotch is an open-source MacBook notch app. It combines an agent hub
(approve and monitor Claude Code and other coding agents from the notch),
everyday widgets, and local memory that stays on your Mac. Its mascot is Platy
the platypus.

**Status:** early development. Expect breaking changes.

The Go core (`core/`) is the `notch` binary that speaks the socket protocol
described in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Install

PlatyNotch needs a Mac with a notch (Apple silicon) and macOS 15 or later.

1. Download `PlatyNotch-<version>.dmg` from
   [GitHub Releases](https://github.com/Vaibhaav-Tiwari/PlatyNotch/releases).
   Each release also has a `.sha256` file: `shasum -a 256 PlatyNotch-*.dmg`
   should print the same value.
2. Open the DMG and drag **PlatyNotch** onto **Applications**.

### Opening PlatyNotch the first time

Releases are not yet signed with an Apple Developer ID or notarized, so the
first time you open the app macOS says it can't verify the developer. To open
it anyway, either:

- try to open PlatyNotch once, then go to **System Settings › Privacy &
  Security**, find the message about PlatyNotch and click **Open Anyway**; or
- run `xattr -dr com.apple.quarantine /Applications/PlatyNotch.app` in
  Terminal, then open the app normally.

Open it from `/Applications`, not from the DMG: the app points
`~/Library/Application Support/PlatyNotch/bin/notch` (the command agent
hooks run) at the copy it is running from.

### Updates

When a release is built with an update key, **Check for Updates…** in the
menu bar item installs new versions, and Settings › About has **Automatically
check for updates**. Otherwise download new versions from
[GitHub Releases](https://github.com/Vaibhaav-Tiwari/PlatyNotch/releases) and
replace the app in Applications.

On-screen capture (memory) uses the Accessibility permission. Because the app
is not Developer ID signed, macOS may not recognise an updated copy as the same
app: if capture stops after an update, untick and re-tick PlatyNotch in
**System Settings › Privacy & Security › Accessibility**.

### Build from source

Needs Xcode (Swift 6), Go (the version in `core/go.mod`) and CMake.

```sh
scripts/build-app.sh            # build/PlatyNotch.app, ad-hoc signed
scripts/make-dmg.sh             # build/PlatyNotch-<version>.dmg
```

`scripts/build-app.sh --sign "Developer ID Application: …"` signs with a
Developer ID and the hardened runtime instead; `scripts/notarize.sh` then
notarizes the DMG.

## Memory and privacy

Memory is **off by default**. Turn it on with `"memory": {"enabled": true}` in
`~/Library/Application Support/PlatyNotch/config.json`.

- **Local only.** Captured screen text is stored in
  `~/Library/Application Support/PlatyNotch/memory.db`, a SQLite file (and its
  `-wal`/`-shm` sidecars) readable only by you (mode `0600`). The database is
  not encrypted by PlatyNotch; turn on **FileVault** to protect it at rest.
- **Nothing leaves your Mac unless you configure a provider.** The default
  embedder and extractor are `none` (keyword search only). If you set one,
  text goes only to that endpoint: `ollama` (local by default) or any
  OpenAI-compatible API. Plain `http://` is refused for anything but
  localhost.
- **Redacted before storage:** private key blocks, JWTs, `sk-` API keys, AWS
  access key ids, GitHub tokens (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`,
  `github_pat_`), Slack tokens (`xox?-`), Google API keys (`AIza…`) and
  Luhn-valid card numbers. Window titles are redacted too, and URLs are kept
  without their query string, fragment or credentials. Redaction is
  pattern-based, so it cannot catch every secret.
- **Never captured:** password managers and Keychain Access by default; add
  bundle ids to `memory.exclude_apps` to skip more apps.
- **Retention:** captures older than `memory.retention_days` (90 by default)
  are deleted and overwritten on disk daily.

### Use your memory from AI apps (MCP)

`notch mcp` is a local stdio MCP server that lets AI apps search your memory
and open loops. Register it with:

```sh
notch mcp install claude-desktop   # or: claude-code, cursor
notch mcp uninstall claude-desktop
```

The server reads `memory.db` on your Mac, but the results go to the AI app
that asked, and that app may send them to its own model provider. Connect
only apps you trust with your screen history.

### On-screen capture (Mac app)

With memory on and Accessibility granted, the app reads the frontmost window's
text through the Accessibility API and sends it to the local core. It never
captures:

- password managers and Keychain Access (always, even if you edit
  `memory.exclude_apps`), apps listed in `memory.exclude_apps`, PlatyNotch
  itself, the login window, or System Settings' password panes;
- secure text fields, or anything while secure input is on, the screen is
  locked, or your session is not on the console;
- private or incognito browser windows. Detection is **heuristic**: it looks
  for "Incognito", "InPrivate", "Private Browsing", "Private Window" or
  "— Private" in the window title and accessibility description, and skips
  browser windows whose title cannot be read. Safari does not always mark a
  Private window, so add Safari to `memory.exclude_apps` (or pause capture)
  if that matters to you.

"Pause capture for 1 hour" is in the Memory tab.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
