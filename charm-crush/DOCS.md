# HASSCrush — Home Assistant add-ons for Charm tools

<p align="center">
  <img src="charm-crush/logo.png" alt="Crush" width="520">
</p>

Charm's terminal AI tools running inside Home Assistant, pointed at your own models and infrastructure.

**Add-on in this repo: [`charm-crush/`](charm-crush/)** — everything below documents it. Install via **Settings → Add-ons → Add-on Store → ⋮ → Repositories** → add `https://github.com/rainyvalley/HASCRUSH`.

---

# HASSCrush — the Crush add-on for Home Assistant

Run [Charm Crush](https://github.com/charmbracelet/crush) — the terminal-first AI coding agent — inside Home Assistant, pointed at **your own Ollama models**, with optional shared memory.

> The ttyd-over-ingress + persistent-tmux add-on shape was inspired by [robsonfelix's claudecode add-on](https://github.com/robsonfelix/robsonfelix-hass-addons). This add-on runs Crush with your Ollama models instead.

## Features

- **Crush in the HA sidebar** — web terminal (ttyd) behind HA's own authentication; opens from the sidebar or "Open Web UI"
- **Your models, any of them** — defaults: **GLM 5.3 Flash** daily (thinking, effort high), **GLM 5.3** deep (effort max); the picker auto-discovers *every* model your providers serve (all Ollama models, not just GLM); refresh = add-on restart
- **Persistent sessions** — tmux survives refresh/disconnect; crushrc + keys live in `/homeassistant/.crushdata/` (HA backups include it)
- **Central config (optional)** — fetch your crushrc from any HTTP URL each start; a fleet of machines shares one config
- **Memory (optional)** — point at any MCP memory server (e.g. a mem0-style shared layer your other chat clients also use); empty = off
- **`ha` CLI preinstalled and pre-authenticated** — Supervisor token env-only, never written to disk

## Requirements

- Home Assistant OS / supervised install (add-on capable)
- An Ollama endpoint: **Ollama Cloud** (ollama.com API key) and/or a **LAN Ollama** host for local/vision models

## Install

1. In HA: **Settings → Add-ons → Add-on Store → ⋮ (top right) → Repositories**, add:
   `https://github.com/rainyvalley/HASCRUSH`
2. Refresh the store; install **Crush**.
3. Configure options (see below) — at minimum an **Ollama API Key** (or a key URL), unless your config template resolves the key itself.
4. Start the add-on; open it from the sidebar (panel title "Crush").

## Options

| Option | Default | Description |
|---|---|---|
| `provider` | `ollama` | `ollama` (Ollama Cloud + LAN) or `third_party` (any OpenAI-compatible API) |
| `third_party_base_url` | *(empty)* | Required with `third_party`: e.g. `https://openrouter.ai/api/v1` |
| `third_party_api_key` | *(empty)* | Required with `third_party` |
| `local_ollama_url` | *(empty)* | LAN Ollama (OpenAI-compatible `/v1`) for local/vision models |
| `crush_config_url` | *(empty)* | HTTP URL fetching your crushrc each start (empty = fallback config) |
| `ollama_api_key` | *(empty)* | Ollama Cloud key (direct; wins over key URL) |
| `ollama_key_url` | *(empty)* | HTTP URL fetching `OLLAMA_API_KEY=...` — validated like `crush_config_url` (http(s), URL-safe chars; plain http warns) |
| `disti_token` | *(empty)* | Optional **X-Disti-Token download credential** for a crush disti that token-gates its secret files (memory/vision/CAD token copies, ollama.key). When set, every key/token_url fetch sends `X-Disti-Token:`. Token charset is URL-safe validated; fetches run without it if invalid. NOT an MCP bearer token — MCP endpoints keep their own per-endpoint auth and work whether or not the disti is used |
| `crush_large_model` | `ollama-cloud/glm-5.3-flash` | Daily default (registration id) |
| `crush_small_model` | `ollama-cloud/glm-5.3-flash` | Helper model (summaries/titles) |
| `crush_deep_model` | `ollama-cloud/glm-5.3` | Deep reasoning model (TUI picker) |
| `crush_reasoning_effort` | `high` | Daily-model thinking effort: `low`/`high`/`max` dropdown |
| `crush_discover_models` | `true` | Auto-discover each provider's full model catalog (Ollama Cloud, LAN Ollama, third-party) into the TUI picker; disable to show only hand-registered models |
| `mcp_servers` | *(empty)* | ALL MCP servers (memory/vision/search/etc.) as one JSON array with per-entry tokens (see MCP servers section); empty = template servers as-is |
| `terminal_font_size` / `terminal_theme` | 14 / dark | Web terminal look |
| `working_directory` | `/homeassistant` | Where crush starts |
| `session_persistence` | `true` | tmux session survives disconnects |
| `auto_update_crush` | `true` | Update crush on add-on start (with rollback) |

## LLM provider: Ollama (default) or any 3rd-party OpenAI-compatible API

The **Provider** picklist in the Options tab chooses where models come from:

- **`ollama`** (default) — models live in your Ollama: `ollama.com/cloud` (key from the API Key option / key URL) + `ollama-local` on your LAN (`local_ollama_url`).
- **`third_party`** — check it and two more fields appear: **Base URL** (e.g. `https://openrouter.ai/api/v1`, `https://api.openai.com/v1`, or any OpenAI-compatible endpoint) and **API Key**. On start, the config's model ids (`ollama-cloud/...`) are remapped to your provider automatically — same models, same slots, different backend.

Examples:

| You want | Options to set |
|---|---|
| Ollama Cloud + LAN Ollama (default) | `provider=ollama`, `ollama_api_key` (or key URL), optional `local_ollama_url` |
| OpenRouter models | `provider=third_party`, `third_party_base_url=https://openrouter.ai/api/v1`, `third_party_api_key=sk-or-...` |
| OpenAI | `provider=third_party`, `third_party_base_url=https://api.openai.com/v1`, `third_party_api_key=sk-...` |
| Any other OpenAI-compatible | `provider=third_party`, its URL + key |

Env equivalents (same precedence chain as everything else): `THIRD_PARTY_BASE_URL`, `THIRD_PARTY_API_KEY`, `LOCAL_OLLAMA_URL`.

## Models: choose, add, refresh

**Choosing at runtime** — in the TUI:
1. Type `/` → pick **models** (or press the model-picker key from the help line).
2. The picker lists every model from your config grouped by provider (`ollama-cloud`, `ollama-local`).
3. Pick `GLM 5.3 Flash` for everyday; pick `GLM 5.3` for deep thinking-heavy tasks; pick a vision model and drop in an image to inspect it.

**Refreshing the model list** — the picker refreshes on add-on restart. With **Auto-discover All Models** (`crush_discover_models`, default on; `--discover-models true` under the hood) every start re-queries each provider's catalog, so new models appear with no config edit. For anything needing explicit metadata (prices, context window, effort), register it:

1. **Central template (recommended for multi-machine)**: edit the template served at your `crush_config_url` URL — then *restart the add-on*. On start it re-fetches, and new models appear in the picker.
2. **Manual**: edit `/homeassistant/.crushdata/config/crush/crushrc` inside the add-on (via the web terminal or the HA file editor), then restart the add-on.

> **Note on refresh**: model registrations are read at crushrc load; the picker only refreshes on add-on (or crush) restart. A running session keeps its startup model catalog.

**Example: adding a new model to the config** (in the central template or the local crushrc):

```bash
# register a cloud model with prices (cost display uses these):
model add ollama-cloud/kimi-k3 --name "Kimi K3" --context-window 1048576 \
  --default-max-tokens 16000 --can-reason true --reasoning-effort high \
  --price-input 3.27 --price-output 16.33
# slots choose the DEFAULT the agent starts with:
model large ollama-cloud/glm-5.3-flash --reasoning-effort high
model small ollama-cloud/glm-5.3-flash --reasoning-effort high
```

## Memory (an MCP memory server)

Memory is one entry in the `mcp_servers` JSON (see next section), not a separate field:

| Want | Set |
|---|---|
| A shared memory layer (e.g. a mem0-style server your other chat clients also use) | its URL + `token`/`token_url` in one entry |
| Another MCP memory server | an entry named anything, its URL + token |
| No memory | omit the memory entry (and set `mcp_servers` if any other server is wanted) |

**Usage from the agent**, once wired (example tool names from a mem0-style memory server; a different server exposes similar ones):

```bash
# the agent recalls automatically (server instructions tell it to search first); manually:
search_memory(query="which camera covered the greenhouse", user_id="you@example.com")
# save something durable:
add_memory(messages='[{"role":"user","content":"Trash cans go out Thursday evenings."}]', user_id="you@example.com")
# audit one memory:
memory_history(memory_id="<id from search>")
```

`user_id` matters: it's the memory space. Use the **same id in every client** and everything shares one brain.

**Multiple users on the same memory server?** If it supports per-token user grants (its README documents the mechanism — e.g. a wrapper mapping tokens to users via an env like `MEM0_USER_<sha256(token)[:8].upper()>=who@example.com,...`), issue one token per user and set each install's memory entry to its own token.

## MCP servers (memory, vision, search, CAD, ...)

**All** MCP servers — memory included — are wired from the Options tab via one option: `mcp_servers`, a JSON array with one entry per server. Entries **replace only their own server's line**; a central template's other `mcp add` lines stay untouched. Empty = template servers as-is. Applies on add-on restart.

**Complete example** (fake host/keys — copy the shape, replace the values):

```json
[{"name":"memory","url":"http://mcp.example.lan:8300/mcp","token_url":"http://mcp.example.lan/memory-mcp.token"},
 {"name":"vision","url":"http://mcp.example.lan:3011/mcp","token":"sample-vision-token"},
 {"name":"search","url":"http://mcp.example.lan:3000/mcp"},
 {"name":"browser","url":"http://mcp.example.lan:8931/mcp"},
 {"name":"cad","command":"socat","args":["STDIO","TCP:mcp.example.lan:3010"],"token_url":"http://mcp.example.lan/cad-mcp.token","timeout":20}]
```

Entry forms:

- **HTTP** — `name` + `url`, plus `token_url` (fetched at startup) or `token` (pasted directly); omit both for tokenless servers (`search`, `browser` above).
- **stdio** — `name` + `command` + `args` (each element becomes one `--args` token, no shell splitting) + optional `timeout`.
- **stdio + token** (since 1.0.25) — `command`/`args` entries also accept `token_url` or `token`. When one resolves, the entry is emitted as a `sh -c` **gate wrapper**: the token goes out as the *first* stdin line, then the command is exec'd (e.g. `socat` relaying to a TCP-only MCP bridge that requires the token first — the `cad` shape above; the relay tool must be in the add-on image, and socat already is). The `docker run`…`STDIO TCP:…` form stays for machines that have their own docker socket.
- If a token URL yields nothing, the server is still added **without** an auth header / gate and a warning lands in the add-on log — a LAN server may legitimately not need auth.

**Combining several servers** is just more array entries; invalid JSON or a nameless entry logs a warning and skips that entry only.

Secrets never land in the generated crushrc: the add-on exports resolved tokens as `MCP_TOKEN_<name>` and the rc references them as `$VARS`, so stored configs stay shareable.

## Central config (optional)

`crush_config_url` = any **plain-HTTP URL** of a crushrc text file. The natural host: another machine already running Crush (share its rc file), or any static server (Caddy, `python -m http.server`, NAS, GitHub Pages). On start the add-on fetches it; keys stay out of the template — the rc resolves secrets from the environment the add-on exports, so one template serves a fleet safely.

Validated at fetch time (since 1.0.22): the URL must be http(s) with URL-safe characters only, the fetched file is capped at 1 MB, and it must still look like a crushrc (`provider` / `model` markers) — anything else falls back to the built-in config with a `[addon][WARN]` in the log. Plain `http://` URLs warn explicitly: the script could be modified in transit on the wire, so prefer `https://` where the host supports it.

**Config-version check (since 1.0.24)**: a central template stamped `# config-version: N` is verified at every start against the matching `/config.version` published beside it. Current → `[addon] crush config-version N - current`; a mismatch or unreachable version is logged as a `[addon][WARN]` so a stale config (or a distribution server with the version file and template out of sync) shows up in the add-on log instead of grinding on silently. Templates without a stamp still work — the check just reports `installed=none`.

## API usage (the `ha` CLI + HA's REST)

`HA_TOKEN` (Supervisor token) and `HA_URL` are in the environment; use them directly:

```bash
# CLI (simplest — it picks up HA_TOKEN/HA_URL automatically):
ha core logs 2>&1 | tail -50
ha core stats
ha host info
ha network info

# raw REST (same token):
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  "$HA_URL/api/states/light.kitchen" | jq '.state'

# call a service:
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entity_id":"switch.office_fan"}' \
  "$HA_URL/api/services/switch/toggle"
```

Crush can run all of this; just ask it to. Note `HA_URL=http://supervisor/core` only resolves inside add-ons.

### Where the Supervisor API key comes from (no field for it - by design)

There is **no option field** for the Supervisor API key, and you never need to paste one:
the Supervisor itself injects a per-install token into the add-on as the environment
variable `SUPERVISOR_TOKEN` (re-exported here as `HA_TOKEN`). It becomes valid only
because `config.yaml` declares the API permissions:

| config.yaml flag | Grants |
|---|---|
| `homeassistant_api: true` | calls to HA Core through the proxy (`http://supervisor/core/api/...`) |
| `hassio_api: true` + `hassio_role: manager` | Supervisor API calls (`http://supervisor/...`) with manager-level reach |
| `auth_api: true` | validating HA usernames/passwords via the Supervisor `/auth` endpoint |

So "adding a key" is not something the Options tab can do - the key rotates with each
install/update and the permission flags are fixed at build time. If you see
`401 Unauthorized` / `403 Forbidden` from these APIs, the fix is to **update or reinstall
the add-on** (so a fresh token gets issued and current permission flags land), not to
fill in a field.

Add-on releases since **1.0.20** also recover the token when s6-overlay stripped the
container environment: startup resolves `SUPERVISOR_TOKEN` from the real environment,
the legacy `HASSIO_TOKEN` alias, and the s6 `container_environment` dump (in that
order), then re-exports it under both names for the `ha` CLI and crush sessions.

**Denials that are normal (do not "fix" them)** - these are the attempts that are
supposed to be denied:

| What was attempted | Response | Why |
|---|---|---|
| `http://supervisor/hassio/...` or `${HA_URL}/api/hassio/...` | 403 | blacklisted path for every add-on (blocks reaching the `hassio` integration through Core) |
| WebSocket command types `supervisor.*` / `hassio.*` via `ws://supervisor/core/websocket` | `unauthorized` | blocked in the core proxy since Supervisor 2026.08 (#7123) - use the `ha` CLI or REST instead |
| `/os/ssh/authorized_keys`, `/addons/<slug>/security` | 403 | need the `admin` role; this add-on deliberately runs `manager` |
| docker CLI / docker socket | fails | no `docker_api`/`full_access` by design (better security rating); toggle **Protection mode** per-install if a task truly needs it |
| a long-lived access token from your HA Profile page against `http://supervisor` | 401 | profile tokens are HA Core tokens - the supervisor proxy only accepts the injected `SUPERVISOR_TOKEN` |

At every add-on start, `run.sh` also self-checks both endpoints (`http://supervisor/info`
and `http://supervisor/core/api/`) and prints an OK or `DENIED <code>` line with the
cause to the add-on log. When the token itself could not be resolved at all, the log
shows a `SUPERVISOR_TOKEN missing` warning instead (see Troubleshooting).

The agent-facing version of these rules ships as the default `CRUSH.md`
(in `/homeassistant/.crushdata/`): a **Hard Limits** block that Crush ingests on
every start, telling it what is already wired (never ask for keys) and which
denials to not retry. Written on first start; pre-1.0.12 installs get it
injected automatically on the next add-on restart (user edits preserved).

## Environment variables

Every option has an env equivalent. **Precedence: real environment > env file > Options tab.**

| Env var | Matches option | Notes |
|---|---|---|
| `THIRD_PARTY_BASE_URL` | Third-Party Base URL | Required with Provider = third_party (OpenAI-compatible endpoint) |
| `THIRD_PARTY_API_KEY` | Third-Party API Key | Required with Provider = third_party |
| `LOCAL_OLLAMA_URL` | LAN Ollama URL | Local Ollama base for `ollama-local` models |
| `CRUSH_LARGE_MODEL` | Default daily model | Registration id (`provider/model`) |
| `CRUSH_SMALL_MODEL` | Helper model | Summaries/titles |
| `CRUSH_DEEP_MODEL` | Deep model | Switch to it via the TUI picker |
| `CRUSH_REASONING_EFFORT` | Daily-model effort | `low` / `high` / `max` |
| `CRUSH_DISCOVER_MODELS` | Auto-discover All Models | `false` disables provider-catalog auto-discovery |
| `OLLAMA_API_KEY` | Ollama API Key | Ollama Cloud key (ollama.com) |
| `OLLAMA_KEY_URL` | Ollama API Key URL | URL fetching `OLLAMA_API_KEY=...` |
| `MCP_SERVERS` | MCP Servers (JSON) | Same JSON array the option takes; beats the Options tab. Per-entry tokens ride inside the array (`token` / `token_url`) |
| `CRUSH_CONFIG_URL` | Central crushrc Template URL | HTTP URL of the shared crushrc |
| `TERM` | — | xterm-256color (set by the add-on) |

**Where to set them**

1. **The env file** — `/homeassistant/.crushdata/env`, one `KEY=VALUE` line each:

   ```bash
   OLLAMA_API_KEY=...
   # MCP_TOKEN_* values are NOT set by hand: the add-on exports one per
   # mcp_servers entry after resolving that entry's own token/token_url.
   # A manually set value is only read by a fetched template that
   # references $MCP_TOKEN_<name> itself.
   ```

   Sourced every start; beats the Options tab; ships in HA backups; `chmod 600`.
   Since 1.0.22 only well-formed `KEY=VALUE` lines are sourced — anything else
   (shell commands, `curl ... | sh`, multiline values) is **skipped and logged**
   with a `[addon][WARN]`, never executed.
2. **The Options tab** — same names, UI form.
3. **Real env** (`docker run -e`, supervised installs only) — highest precedence.

A fetched central crushrc resolves its secrets from these envs — never inline — so one template stays fleet-safe.

## File locations (inside the add-on)

| Path | Purpose |
|---|---|
| `/homeassistant/.crushdata/config/crush/crushrc` | your crushrc (persistent, fetched-from-template or hand-edited) |
| `/homeassistant/.crushdata/config/crush/ollama.env` | persisted API keys (chmod 600; in HA backups) |
| `/homeassistant/.crushdata/CRUSH.md` | standing instructions (path mapping, `ha` usage, log levels) |
| `/homeassistant/.crushdata/data/` | crush session data |
| `/homeassistant/.crushdata/env` | optional env-file defaults (KEY=VALUE; wins over the Options tab) |
| `/homeassistant/.crushdata/tmux.conf` | user tmux overrides (sourced last) |

## Security

- **Better security rating**: the add-on requests only Supervisor-manager + Home Assistant APIs and
  mapped folders — **no `full_access`, no Docker API** (HA shows rating ~3 instead of 1). If a task
  ever needs host/docker access, toggle **Protection mode** for this add-on in Settings (per-install
  decision; raises the rating back to 1 while enabled).
- The Supervisor token (`SUPERVISOR_TOKEN`) is env-only; never written to disk or configs.
- The web terminal is a pinned static `ttyd` binary (sha256-verified at image build since 1.0.22);
  it serves a live shell over the add-on's port and is **only reachable through HA ingress** —
  HA's own authentication is the boundary in front of it, and it is never published directly.
- API keys persist inside the HA config dir — included in HA backups. Protect backups accordingly,
  and rotate keys if a backup leaves your control.
- The memory layer is LAN-authenticated separately by its own bearer; don't reuse tokens across services.

## Troubleshooting

- **"Choose a model" onboarding on first launch**: no crushrc resolved — check the add-on log for `[addon]` lines. Set `ollama_api_key` or confirm `crush_config_url` is reachable from the HA host.
- **`Unauthorized` errors in crush**: stale key — set the `ollama_api_key` option directly (it wins over everything), then restart the add-on.
- **Model not in picker**: confirm the **Auto-discover All Models** option is on and restart the add-on (it lists every model the provider catalog exposes); for prices/ctx/vision metadata, register the model explicitly in the crushrc (central template or local file)
- **`ha` command errors**: `HA_URL`/`HA_TOKEN` are automapped; if `ha` still fails, check the Supervisor connection with `curl -s $HA_URL/api/ -H "Authorization: Bearer $HA_TOKEN"`.
- **Supervisor API `401` / `403` denials**: there is deliberately **no field to add a Supervisor API key** —
  the Supervisor injects `SUPERVISOR_TOKEN` itself, and `config.yaml`'s `homeassistant_api` / `hassio_api` /
  `hassio_role: manager` flags grant its reach (see *Where the Supervisor API key comes from* above).
  Distinguish the two failure modes in the startup self-check lines of the add-on log:
  - `SUPERVISOR_TOKEN missing` (present before 1.0.20; the s6 base stripped the container env before
    startup could read it): **update the add-on** — 1.0.20+ keeps the environment intact and recovers
    the token from the s6 dump.
  - `token DENIED 401` / `access DENIED 403` (token present but rejected): if the self-check shows
    `Supervisor API: OK` lines, the key is fine and any remaining denials are the *expected* ones
    (hassio paths, `supervisor.*` websocket commands, docker, admin-only endpoints); otherwise update
    or reinstall the add-on so a fresh token + current permission flags are issued.
  Never paste a Profile-page long-lived token into any field — it does not work against
  `http://supervisor`. Note: **updating the add-on re-keys it**; tokens are only valid for the current
  install.
- **Memory-server tool errors**: run `crush logs` / check the add-on log — an entry in `mcp_servers` with no reachable URL or no token will say so; 401 = the token on that entry is wrong.
- **GPU slowness elsewhere**: this add-on never runs models; it talks to your Ollama over the network. Slowness under load usually lives in the Ollama host (shared GPU).

## License

MIT — see [LICENSE](LICENSE).