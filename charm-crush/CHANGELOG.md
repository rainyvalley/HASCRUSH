# Changelog

All notable changes to the HASSCrush (Charm Crush) Home Assistant add-on will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.47] - 2026-10-19

### Changed
- Housekeeping only, no behaviour change: the Model Options-tab text no
  longer mentions the touch bar's removed `Model` key, and stale source
  comments were dropped.

## [1.0.46] - 2026-10-18

### Changed
- **The touch bar only appears on touch devices.** A desktop browser (fine
  primary pointer) no longer gets the key row at all: no bar, no space
  reserved, the terminal uses the full window.
- **The `Model` key was removed** from the touch bar (crush's model picker
  did not open reliably from it). Use `/` → *models* in the TUI, or the
  `Ctrl+L` binding.

## [1.0.45] - 2026-10-18

### Security
- **Store security rating raised to 8/8.** Two changes: the add-on no longer
  asks for the Supervisor `manager` role (default role only, so it can call
  the Core API and `/supervisor/info` but cannot manage add-ons, backups, the
  host or the OS), and it now ships its own AppArmor profile (`apparmor.txt`)
  that confines kernel-facing surfaces while leaving the terminal workload
  inside the container free. `full_access`/Docker access/host networking stay
  off as before.
- **The agent's guardrails were updated to match**: the "Hard Limits" block it
  reads at startup now lists Supervisor-side management as denied by design and
  points at Core-only `ha` commands as the alternative.

## [1.0.44] - 2026-10-18

### Changed
- **The touch-bar offset is chosen per platform automatically.** Left at `0`,
  the bar now trims 40px on iOS/iPadOS (where the browser over-reports the
  keyboard height) and nothing on Android/desktop. Entering any non-zero
  value still overrides that outright, so quirky devices can be corrected the
  same way as before. Existing installs keep their saved value.
- README and DOCS are now the same document again (the Documentation tab had
  drifted: model picklists, custom model overrides, touch bar, debug option).

## [1.0.43] - 2026-10-18

### Changed
- **`Touch Bar Offset` now defaults to -40**, a value tuned on iOS/iPadOS
  where the browser over-reports the keyboard height by a small amount.
  Android and desktop setups usually want 0; existing installs keep whatever
  value they have already saved.

## [1.0.42] - 2026-10-18

### Fixed
- **No more dark strip under the keys.** The bar reserved the browser's
  safe-area inset below the key row; on phones where that inset is large it
  showed as a black band between the keys and the on-screen keyboard. The
  keys now sit directly on the keyboard, and `Touch Bar Offset` can go back
  to 0.

## [1.0.41] - 2026-10-18

### Added
- **`Touch Bar Debug` option.** Draws a one-line diagnostic above the touch
  bar with the raw numbers behind its keyboard lift (window height, visual
  viewport, own/ancestor coverage, resting baseline, offset, final shift), so
  a phone that reports its keyboard inset incorrectly can be diagnosed from a
  screenshot. Off by default.

## [1.0.40] - 2026-10-18

### Changed
- **Model options are picklists instead of text fields.** The daily, helper
  and deep slots now offer a dropdown of the models this release knows
  (DeepSeek V4.1 Flash, GLM 5.3 / 5.3 Flash, Kimi K3, Gemma 4 31B, the local
  Qwen3-VL vision model). For anything else - LAN Ollama tags or other
  catalog ids - use the new `Custom ... Model` field, which wins when set.
  **Upgrading with a hand-typed model id:** move it into the matching custom
  field, otherwise the slot falls back to the dropdown default.

### Added
- **Model key on the touch bar.** It opens crush's own model picker (Ctrl+L),
  which lists every model discovered from your providers - the live list,
  refreshed whenever the add-on restarts.

## [1.0.39] - 2026-10-18

### Fixed
- **The touch bar sits on the keyboard again.** The keyboard lift combined
  the page's own viewport change and the panel frame's measurement, which
  double-counted on phones where both move, leaving a dead band below the
  keys. It now takes the larger single measurement and subtracts whatever is
  already covered at rest.

### Added
- **`Touch Bar Offset` option (pixels, -400..400).** For phones/browsers that
  report the keyboard height imprecisely: set a negative value (e.g. -260) to
  lower the bar when a dark band stays under the keys, positive to lift it
  when the keys hide behind the keyboard. Applies on add-on restart.

## [1.0.38] - 2026-10-18

### Changed
- **The touch bar no longer draws a bar.** The full-width dark strip is gone:
  the six keys are now compact floating pills (frosted, rounded, theme-aware)
  and the space around them is click-through, so the terminal stays visible
  right up to the keys. The bar's footprint shrank accordingly.

## [1.0.37] - 2026-10-18

### Fixed
- **The touch bar also follows the keyboard inside the Home Assistant panel.**
  The add-on page runs in a same-origin iframe there, and the keyboard
  shrinks the panel's (parent) viewport rather than the page's own, so the
  bar still stayed behind it in 1.0.36. The bar now measures the parent
  frame chain too (with a light poll for browsers that skip resize events),
  and lifts above the keyboard in the sidebar panel and in a full browser
  tab alike.

## [1.0.36] - 2026-10-18

### Fixed
- **The touch bar now floats above the on-screen keyboard.** The software
  keyboard does not shrink the page, so the bar used to stay behind it; it
  now follows the visible area (and the terminal shrinks to match), keeping
  Ctrl/Alt/Tab/Esc/Del/Paste reachable while typing, and returns to the
  bottom when the keyboard closes.

## [1.0.35] - 2026-10-18

### Added
- **Touch bar for the web terminal**, on by default and toggleable in the
  Options tab (`Touch Bar`). A small bar at the bottom of the terminal page,
  made for phones/tablets: `Ctrl`, `Alt` and `Tab` latch like held keys (the
  next key tapped or typed is composed with them and they then release; tap
  the same key again to release early), while `Esc`, `Del` and `Paste` fire
  immediately. Paste reads the browser clipboard; on a plain-HTTP connection
  it falls back to a paste-into-box dialog. The bar is served by ttyd itself
  (its custom-index feature) over the same connection and ports as before -
  no change to the transport or the ingress gate - and any missing piece
  degrades to the plain terminal with a log line.

## [1.0.34] - 2026-10-13

### Changed
- **DeepSeek V4.1 Flash is the new default model** for the daily, helper and
  deep tiers. The daily and helper slots run it at reasoning effort `high`;
  the deep tier runs the same model at `max` (`crush_reasoning_effort`).
  GLM 5.3 Flash and GLM 5.3 stay registered and selectable in the picker.
- Existing installs keep any model options they have already saved; only
  unset slots pick up the new defaults.

## [1.0.33] - 2026-10-13

### Changed
- **`auto_update_crush` now defaults to off** for new installs. Existing
  installs keep their saved value.

### Security
- **The web terminal is reachable only from the Home Assistant ingress
  address.** ttyd now listens on loopback only, behind a small socat gate that
  accepts just the Supervisor ingress source address. The `X-Hass-Source`
  header check stays as a second layer.

## [1.0.32] - 2026-10-13

### Security
- **The `ha` CLI download is checksum-verified** per architecture when the
  image is built.
- **MCP token collisions are rejected.** Server names such as `a-b` and `a_b`
  map to the same token variable; such entries are now refused instead of
  silently sharing a token.
- **Switching provider no longer risks the wrong host.** The original base URL
  is recorded and restored when the third-party remap is undone, instead of
  assuming ollama.com.

### Changed
- `mcp_servers` entries are parsed in a single pass, with test coverage.

## [1.0.31] - 2026-10-12

### Fixed
- **Hyphenated MCP server names** (for example `home-assistant`) no longer
  abort the boot; their token variable now uses `_` in place of `-`.
- **The deep model is no longer re-appended to the crushrc on every start.**
  Lines already appended by earlier boots stay but stop growing.
- **Third-party provider:** the model slot options (large/small/deep) are now
  remapped along with the config, and the remap is undone on every start. A
  stale third-party host no longer receives the new key after you switch
  provider or change the base URL.
- A third-party boot no longer leaves a stray `crushrcE` backup file in the
  persisted config directory.

### Changed
- Faster boot on small ARM boards: each `mcp_servers` entry is read with one
  `jq` call instead of one per field.

### Removed
- A dead 7681/tcp label in the Network translations (the add-on is
  ingress-only and never declared that port).

## [1.0.30] - 2026-10-10

### Changed
- Internal: pure helper functions moved from `run.sh` into `rootfs/lib.sh`,
  with a bats test suite and extra lint steps in CI. No behaviour change
  intended.

## [1.0.29] - 2026-10-09

### Fixed
- **`crush_discover_models: false` is honoured.** It was previously ignored,
  so model discovery could not be switched off from the Options tab.
- **No spurious warning on a default install.** The empty default of
  `mcp_servers` was parsed as invalid JSON and logged a warning.
- Model-slot and terminal options are read in one pass, so values containing
  newlines or quotes stay intact.
- Delivers the fixes made after 1.0.28 (that version number had already
  shipped without them).

### Changed
- Smaller image: unused packages (`gnupg`, an empty PATH layer) removed.

## [1.0.28] - 2026-10-09

### Fixed
- **A crushrc whose last line has no trailing newline** (as the central
  template does) no longer loses that line when MCP entries are removed or
  repaired, which previously left a dangling `if` and broke Crush at start.
- Indented `mcp add` entries inside `if` blocks are handled correctly, so the
  `ollama` MCP registration is no longer eaten as an orphaned fragment.

## [1.0.27] - 2026-10-09

### Security
- **Stricter file permissions.** Everything under the persisted data
  directory (keys, fetched tokens) is created owner-only (`umask 077`).
- **Safer env file.** Lines with unbalanced trailing quotes or
  comment-substitution payloads (such as `KEY=v#$(cmd)`) are rejected instead
  of being sourced as code.
- MCP token fetches are capped at 64 KB and 10 seconds.
- **Direct access to the terminal port is header-gated.** ttyd requires the
  `X-Hass-Source` header that Home Assistant ingress stamps. This is an origin
  check, not user authentication (see the Documentation tab).

### Changed
- Smaller image (fewer COPY layers); the container healthcheck sends the
  required ingress header.
- MCP and memory docs no longer carry other projects' branding outside
  examples.

## [1.0.26] - 2026-10-06

### Added
- **Model auto-discovery.** New `crush_discover_models` option (default on)
  makes the model picker list every model your configured providers serve
  (ollama.com, a LAN Ollama, a third-party endpoint), not only the
  hand-registered set. Explicitly registered models keep their metadata.
  `CRUSH_DISCOVER_MODELS` overrides it from the environment.

### Changed
- The store listing and headings use the name HASSCrush.
- Documentation cleanups (MCP token wording, translations synced with the
  stdio token gate).

## [1.0.25] - 2026-10-06

### Added
- **Token-gated stdio MCP entries.** `stdio` entries in `mcp_servers`
  (command/args, for example socat relays to an MCP bridge) now accept `token`
  or `token_url`. The token is passed to the command as its first stdin line
  and is referenced via an environment variable, never written into the
  crushrc. A failed token fetch warns and adds the entry ungated.

## [1.0.24] - 2026-10-06

### Added
- **Central config version check.** On every start the add-on compares the
  `# config-version` stamp in the resolved crushrc with the one published by
  the central config source and logs whether it is current, out of sync or
  stale. Informational only; the config is still fetched and applied as
  before.

## [1.0.23] - 2026-10-06

### Added
- **`disti_token` option.** When set, `ollama_key_url` and `mcp_servers`
  `token_url` fetches send it as an `X-Disti-Token` header, for token-gated
  distribution points. It is a download credential only (never an MCP bearer
  token) and is never stored.

## [1.0.22] - 2026-10-06

### Security
- **URL validation.** Config, key and token URLs must be http(s) with a
  strict character set; fetched crushrc content is sanity-checked and capped
  at 1 MB; plain-HTTP fetches log a warning.
- **The env file can no longer run commands.** Only strict `KEY=VALUE` lines
  are loaded.
- **Pinned downloads.** crush and ttyd are verified by sha256 at build time.
- CI now fails on key-looking strings and private IP addresses in tracked
  files.

## [1.0.21] - 2026-10-05

### Changed
- Store and image descriptions are model-agnostic (any Ollama or third-party
  model, optional MCP tie-ins).

## [1.0.20] - 2026-10-05

### Fixed
- **The Supervisor token now reaches startup, the `ha` CLI and Crush
  sessions.** `S6_KEEP_ENV=1` is set so s6 no longer strips the environment,
  and the token is also recovered from its legacy alias and the s6 env dumps.
  The startup log now distinguishes a missing token from a denied one.

## [1.0.19] - 2026-10-04

### Fixed
- **Pasted or editor-wrapped `mcp_servers` values** no longer produce a
  broken crushrc ("unknown flag ..." on every start). All extracted values are
  stripped of CR/LF and the crushrc is re-sanitized after the merge.

## [1.0.18] - 2026-10-04

### Fixed
- The startup repair pass now rejoins tokens that were split mid-word in the
  persisted crushrc and drops orphaned fragments; non-MCP continuations are
  untouched. Rendered `--args` values have CR/LF stripped.

## [1.0.17] - 2026-10-04

### Fixed
- **Self-healing crushrc.** Installs damaged by the pre-1.0.14 delete logic
  (orphaned `--args`/`--timeout` fragments causing "mcp add: unknown flag"
  errors) are repaired automatically on the next start.

## [1.0.16] - 2026-10-03

### Changed
- **`mcp_servers` is the single place to configure MCP servers.** The
  `mem0_mcp_token` and `mem0_mcp_token_url` options are retired; each entry
  carries its own `token` or `token_url`. The documentation gains a complete
  example covering every entry form.

## [1.0.15] - 2026-10-03

### Changed
- **The memory (mem0) MCP server moves into `mcp_servers`.** `mem0_mcp_url`
  is retired and a notice in the add-on log points to the new entry form.
  `mem0_mcp_token` / `mem0_mcp_token_url` keep working as token sources for a
  mem0 entry that sets none of its own.

### Fixed
- More robust MCP entry removal when continuation lines are involved.

## [1.0.14] - 2026-10-03

### Fixed
- **Removing an `mcp_servers` entry deletes all its lines.** Only the first
  line of multi-line entries used to be removed, leaving fragments that broke
  Crush ("mcp add: unknown flag network").
- **stdio `--args`** are rendered in the space form that Crush accepts.

## [1.0.13] - 2026-10-03

### Added
- **`mcp_servers` option.** One JSON array in the Options tab wires any MCP
  server (http entries with `url`/`token`/`token_url`, or stdio entries with
  `command`/`args`/`timeout`) without editing the central template or the
  persisted file. Entries merge by name, are idempotent across restarts, and
  tokens are passed through environment variables rather than stored in
  files. The `MCP_SERVERS` environment variable takes precedence over the
  option.

## [1.0.12] - 2026-10-02

### Added
- **Agent guardrails in CRUSH.md.** A "Hard Limits" block tells the agent that
  keys are pre-wired (never ask the user for one) and lists the expected
  Supervisor denials with safe alternatives. Existing installs get the block
  on next restart without losing their own CRUSH.md edits.

## [1.0.11] - 2026-10-02

### Added
- **Supervisor API self-check.** Each start logs an OK or DENIED line for the
  Supervisor and Core API with the likely cause.
- A "Where the Supervisor API key comes from" section and a denial table in
  the documentation.

## [1.0.10] - 2026-10-01

### Changed
- Bolder boxed "C" sidebar icon.

## [1.0.9] - 2026-10-01

### Changed
- Sidebar icon is now the "C" (`mdi:alpha-c`) instead of a heart.

## [1.0.8] - 2026-10-01

### Fixed
- **Crush failed with "$HOME is not defined".** `HOME`, `USER` and `SHELL` are
  pinned and `S6_KEEP_ENV=1` is set so tmux, bash and crush see a proper
  environment.

## [1.0.7] - 2026-10-01

### Fixed
- **Fallback crushrc never received a key that existed only in the persisted
  `ollama.env`**, which surfaced as a confusing "home is not defined" error.
  Existing fallback configs are migrated on boot.

## [1.0.6] - 2026-10-01

### Changed
- Dropped the custom AppArmor profile; Home Assistant's default profile
  covers the s6 boot correctly.

## [1.0.5] - 2026-10-01

### Fixed
- Startup blocked by AppArmor on files s6 creates under `/run/s6` at boot
  (superseded by 1.0.6).

## [1.0.4] - 2026-10-01

### Fixed
- Startup blocked by AppArmor on s6 binaries copied into `/run/s6` (superseded
  by 1.0.6).

## [1.0.3] - 2026-10-01

### Fixed
- **"can only run as pid 1" / permission-denied at start.** `init: false` so
  s6-overlay runs as pid 1.

## [1.0.2] - 2026-10-01

### Fixed
- AppArmor grants for the s6 symlink chain used at container start
  (superseded by 1.0.6).

## [1.0.1] - 2026-10-01

### Added
- **Provider choice.** New `provider` option: Ollama (default) or a
  third-party OpenAI-compatible API (base URL and key required), which remaps
  the default models onto that endpoint. A LAN Ollama URL can also be set.
- **Model options.** `crush_large_model`, `crush_small_model`,
  `crush_deep_model` and `crush_reasoning_effort` pick the models and effort
  from the Options tab; effort applies to the daily slots only.
- **Env file and env-first precedence.** An optional
  `/homeassistant/.crushdata/env` file (strict `KEY=VALUE` lines); every
  setting resolves real env, then env file, then Options tab, then central
  URL, then the persisted key file.
- A **Documentation tab** (`DOCS.md`), a full README, and new icons.

### Changed
- Renamed to HASSCrush in the store and sidebar.
- Not granting `full_access` / `docker_api`, so the security rating is
  better; Protection mode can be switched off if you truly need host access.
- Builds on the plain Alpine 3.21 base image for both architectures.

### Fixed
- Startup hardening: weird characters in third-party keys, optional LAN
  Ollama lines only written when a URL is set, mem0 line skipped with a
  warning when its token is missing, a missing `/root/.local/share` no longer
  kills startup, and a missing Supervisor token no longer aborts boot.
- The third-party remap only renames the cloud provider (it also renamed the
  local one, orphaning the vision model); `CRUSH.md` is written once so your
  edits survive restarts.

## [1.0.0] - 2026-10-01

Initial release.

### Added
- Charm Crush AI agent in the Home Assistant sidebar: ttyd web terminal over
  ingress with a persistent tmux session.
- Crush config and API key persisted under `/homeassistant/.crushdata`;
  central-config fetch with a built-in fallback.
- mem0 MCP wiring and the `ha` CLI preinstalled.
