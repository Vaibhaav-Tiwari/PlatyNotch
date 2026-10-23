# PlatyNotch

PlatyNotch is an open-source MacBook notch app. It combines an agent hub
(approve and monitor Claude Code and other coding agents from the notch),
everyday widgets, and local memory that stays on your Mac. Its mascot is Platy
the platypus.

**Status:** early development. Expect breaking changes.

The Go core (`core/`) is the `notch` binary that speaks the socket protocol
described in [docs/PROTOCOL.md](docs/PROTOCOL.md).

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

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
