# HASSCrush — Home Assistant add-ons for Charm tools

<p align="center">
  <img src="charm-crush/logo.png" alt="Crush" width="520">
</p>

Charm's terminal AI tools running inside Home Assistant, pointed at your own models and infrastructure.

**Add-on in this repo: [`charm-crush/`](charm-crush/)** — everything below documents it. Install via **Settings → Add-ons → Add-on Store → ⋮ → Repositories** → add `https://github.com/rainyvalley/HASCRUSH`.

---

# HASSCrush — the Crush add-on for Home Assistant

Runs [Charm Crush](https://github.com/charmbracelet/crush), a terminal-based AI coding agent, inside Home Assistant. It works with Ollama (cloud or on your LAN) or any OpenAI-compatible API, and can connect to MCP servers such as a memory layer.

> The ttyd-over-ingress + persistent-tmux add-on shape was inspired by [robsonfelix's claudecode add-on](https://github.com/robsonfelix/robsonfelix-hass-addons).

## What it does today

- **Crush in the HA sidebar.** A web terminal (ttyd) served through HA ingress, so HA's own login protects it. It opens from the sidebar or "Open Web UI".
- **Model providers.** Ollama Cloud and/or a LAN Ollama host, or any OpenAI-compatible API (OpenRouter, OpenAI, and similar) through the `third_party` provider.
- **Model slots.** Separate daily, helper and deep models, each chosen from a picklist or set to a custom model id. Reasoning effort is configurable. The in-terminal picker (Ctrl+L) lists every model the providers expose.
- **Persistent sessions.** tmux keeps the session across refreshes and disconnects. Config and keys live in `/homeassistant/.crushdata/` and are included in HA backups.
- **MCP servers.** Memory, vision, search, CAD or any other MCP server over HTTP or stdio, configured from one Options field. Tokens can be pasted or fetched from a URL.
- **Central config (optional).** Fetch a shared crushrc from an HTTP URL on every start, so several machines can use one config.
- **Touch bar (optional).** An on-screen key bar (Ctrl, Alt, Tab, Esc, Del, Paste) for phones and tablets. It only appears on touch devices.
- **Home Assistant access.** The `ha` CLI is preinstalled, and `HA_URL` / `HA_TOKEN` are set so Crush can call the Core REST API and the Supervisor API (see [Home Assistant API access](#home-assistant-api-access)).
- **Optional auto-update.** Crush can update itself on add-on start, with rollback. It is off by default.

## Requirements

- Home Assistant OS or a supervised install (anything that supports add-ons).
- At least one model source: an Ollama Cloud API key, a LAN Ollama host, or an OpenAI-compatible API key.

## Install

1. In HA: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**, add `https://github.com/rainyvalley/HASCRUSH`.
2. Refresh the store and install **Crush**.
3. In the **Configuration** tab, set a model source (for example `ollama_api_key`, or `provider: third_party` with a base URL and key).
4. Start the add-on and open it from the sidebar.

## Options

| Option | Default | Description |
|---|---|---|
| `provider` | `ollama` | `ollama` (Ollama Cloud + LAN) or `third_party` (any OpenAI-compatible API) |
| `third_party_base_url` | *(empty)* | Required with `third_party`, e.g. `https://openrouter.ai/api/v1` |
| `third_party_api_key` | *(empty)* | Required with `third_party` |
| `local_ollama_url` | *(empty)* | LAN Ollama (OpenAI-compatible `/v1`) for local or vision models |
| `ollama_api_key` | *(empty)* | Ollama Cloud key; wins over the key URL |
| `ollama_key_url` | *(empty)* | HTTP URL returning `OLLAMA_API_KEY=...`; validated like `crush_config_url` (http(s), URL-safe characters; plain http logs a warning) |
| `crush_config_url` | *(empty)* | HTTP URL of a crushrc fetched on each start; empty uses the built-in config |
| `disti_token` | *(empty)* | Optional download credential sent as `X-Disti-Token` on key and token fetches, for a config server that gates its secret files. Not an MCP bearer token |
| `crush_large_model` | `ollama-cloud/deepseek-v4.1-flash` | Daily model (picklist) |
| `crush_large_model_custom` | *(empty)* | Free-form model id; overrides the daily picklist when set |
| `crush_small_model` | `ollama-cloud/deepseek-v4.1-flash` | Helper model for summaries and titles (picklist) |
| `crush_small_model_custom` | *(empty)* | Free-form id; overrides the helper picklist |
| `crush_deep_model` | `ollama-cloud/deepseek-v4.1-flash` | Deep-reasoning model (picklist) |
| `crush_deep_model_custom` | *(empty)* | Free-form id; overrides the deep picklist |
| `crush_reasoning_effort` | `high` | Daily-model thinking effort: `low`, `high` or `max` |
| `crush_discover_models` | `true` | Add each provider's full model catalog to the picker; off shows only registered models |
| `mcp_servers` | *(empty)* | All MCP servers as one JSON array (see [MCP servers](#mcp-servers)); empty keeps the template's servers |
| `terminal_font_size` / `terminal_theme` | 14 / dark | Web terminal appearance |
| `touch_bar` | `true` | Key bar on touch devices; desktop browsers with a fine pointer get no bar. Applies on restart |
| `touch_bar_offset` | `0` | Extra px to lift the bar above the on-screen keyboard (-400..400). `0` uses the platform default (-40 on iOS/iPadOS, 0 elsewhere); any other value overrides it |
| `touch_bar_debug` | `false` | Draw viewport diagnostics above the bar, for phones where it sits wrong |
| `working_directory` | `/homeassistant` | Where Crush starts |
| `session_persistence` | `true` | Keep the tmux session across disconnects |
| `auto_update_crush` | `false` | Update Crush on add-on start, with rollback. When on, the latest upstream release is downloaded and run on every start, verified against a checksum published in the same release |

## Providers

The `provider` option chooses where models come from.

- **`ollama`** (default): Ollama Cloud (`ollama_api_key` or `ollama_key_url`) plus an optional LAN host (`local_ollama_url`).
- **`third_party`**: set `third_party_base_url` and `third_party_api_key`. On start, the config's `ollama-cloud/...` model ids are remapped to your provider.

| You want | Set |
|---|---|
| Ollama Cloud (and optionally a LAN host) | `provider=ollama`, `ollama_api_key`, optionally `local_ollama_url` |
| OpenRouter | `provider=third_party`, `third_party_base_url=https://openrouter.ai/api/v1`, `third_party_api_key=...` |
| OpenAI | `provider=third_party`, `third_party_base_url=https://api.openai.com/v1`, `third_party_api_key=...` |
| Another OpenAI-compatible API | `provider=third_party`, its URL and key |

## Models

**Switching.** In the terminal press Ctrl+L (or type `/` and choose *models*). The picker lists every model from your config, grouped by provider, including the auto-discovered catalog.

**Refreshing.** The list is read when the add-on starts. With `crush_discover_models` on, each start re-queries every provider's catalog, so new models appear after a restart. A running session keeps the catalog it started with.

**Registering a model with metadata** (prices, context window, reasoning effort) goes in the crushrc, either in the central template at `crush_config_url` or in `/homeassistant/.crushdata/config/crush/crushrc`. Restart the add-on afterwards.

```bash
model add ollama-cloud/example-model --name "Example Model" --context-window 1048576 \
  --default-max-tokens 16000 --can-reason true --reasoning-effort high \
  --price-input 3.27 --price-output 16.33
# slots pick the default model for each role:
model large ollama-cloud/example-model --reasoning-effort high
model small ollama-cloud/example-model --reasoning-effort high
```

## MCP servers

All MCP servers, memory included, are configured by one option, `mcp_servers`: a JSON array with one entry per server. Entries replace only their own server's line; any other `mcp add` lines in a central template are left alone. Empty keeps the template as it is. Applies on restart.

```json
[{"name":"memory","url":"http://mcp.example.lan:8300/mcp","token_url":"http://mcp.example.lan/memory-mcp.token"},
 {"name":"vision","url":"http://mcp.example.lan:3011/mcp","token":"sample-vision-token"},
 {"name":"search","url":"http://mcp.example.lan:3000/mcp"},
 {"name":"cad","command":"socat","args":["STDIO","TCP:mcp.example.lan:3010"],"token_url":"http://mcp.example.lan/cad-mcp.token","timeout":20}]
```

Entry forms:

- **HTTP:** `name` and `url`, plus `token_url` (fetched at start) or `token` (pasted). Omit both for servers that need no auth.
- **stdio:** `name`, `command` and `args` (each element is passed as one argument, with no shell splitting), plus an optional `timeout`.
- **stdio with a token:** `command`/`args` entries also accept `token_url` or `token`. The entry then runs through a small `sh -c` wrapper that writes the token as the first stdin line before starting the command, for example `socat` relaying to a TCP bridge that expects a token first.
- If a token URL returns nothing, the server is still added without auth and a warning is written to the add-on log.
- Invalid JSON or an entry without a name logs a warning and skips that entry only.

Resolved tokens are exported as `MCP_TOKEN_<name>` and the generated crushrc refers to them as `$VARS`, so stored configs stay shareable. `-` in a server name becomes `_` in the variable name (`home-assistant` → `MCP_TOKEN_home_assistant`). Two names that map to the same variable collide, and the later token-bearing entry is skipped with a warning.

**Memory.** A memory server is just an entry in this array. Use the same `user_id` in every client that talks to the same memory server, so they share one memory space. If the server supports per-token user mapping, issue one token per user and give each install its own.

## Central config

`crush_config_url` points to a crushrc text file served over HTTP: another machine running Crush, a static file server or a NAS all work. The file is fetched on every start. Keep secrets out of it: the rc reads them from the environment the add-on exports, so one template can serve several machines.

Checks applied to the fetch:

- The URL must be http(s) with URL-safe characters. Plain `http://` logs a warning, so prefer `https://` where available.
- The file is capped at 1 MB and must look like a crushrc (`provider` / `model` markers). Otherwise the built-in config is used and a `[addon][WARN]` line is logged.
- A template stamped `# config-version: N` is compared at each start against `/config.version` published next to it. The log reports whether the installed config is current or stale. Templates without a stamp still work.

## Home Assistant API access

`HA_URL` and `HA_TOKEN` are set in the environment, and the `ha` CLI picks them up automatically. Crush can run these itself; just ask.

```bash
ha core logs 2>&1 | tail -50
ha core stats
ha host info

# REST against Home Assistant Core
curl -s -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/states/light.kitchen" | jq '.state'

# call a service
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" -H "Content-Type: application/json" \
  -d '{"entity_id":"switch.office_fan"}' "$HA_URL/api/services/switch/toggle"
```

`HA_URL` is `http://supervisor/core`, which only resolves inside add-ons. There is no option for a Home Assistant token; Home Assistant provides one to the add-on. Long-lived access tokens from your profile page don't work against `http://supervisor`.

The add-on runs with the Supervisor `manager` role: it can use the Core API, read Supervisor info, and run `ha core check`, `ha core logs`, `ha core stats` and `ha supervisor logs`. The following are expected to be refused:

| Attempt | Result |
|---|---|
| `/hassio/...` or `/api/hassio/...` paths | 403 |
| `supervisor.*` / `hassio.*` WebSocket commands | `unauthorized`; use the `ha` CLI or REST |
| Admin-only endpoints (`/os/ssh/authorized_keys`, `/addons/<slug>/security`, ...) | 403 (needs the `admin` role) |
| docker CLI or socket | not available (no `docker_api` / `full_access`) |

At each start the add-on log prints an OK or `DENIED <code>` line for the Supervisor and Core endpoints. A default `CRUSH.md` is written to `/homeassistant/.crushdata/` on first start with the same limits, so the agent doesn't keep retrying refused calls. Your edits to it are kept.

## Environment variables

Every option has an environment equivalent. Precedence: **real environment > env file > Options tab**.

| Env var | Matches option | Notes |
|---|---|---|
| `THIRD_PARTY_BASE_URL` | `third_party_base_url` | Required with `provider=third_party` |
| `THIRD_PARTY_API_KEY` | `third_party_api_key` | Required with `provider=third_party` |
| `LOCAL_OLLAMA_URL` | `local_ollama_url` | Base URL for `ollama-local` models |
| `CRUSH_LARGE_MODEL` | `crush_large_model` | Registration id (`provider/model`) |
| `CRUSH_SMALL_MODEL` | `crush_small_model` | Summaries and titles |
| `CRUSH_DEEP_MODEL` | `crush_deep_model` | Deep-reasoning model |
| `CRUSH_REASONING_EFFORT` | `crush_reasoning_effort` | `low`, `high` or `max` |
| `CRUSH_DISCOVER_MODELS` | `crush_discover_models` | `false` disables catalog discovery |
| `OLLAMA_API_KEY` | `ollama_api_key` | Ollama Cloud key |
| `OLLAMA_KEY_URL` | `ollama_key_url` | URL returning `OLLAMA_API_KEY=...` |
| `MCP_SERVERS` | `mcp_servers` | Same JSON array; per-entry tokens go inside it |
| `CRUSH_CONFIG_URL` | `crush_config_url` | HTTP URL of the shared crushrc |

**Where to set them**

1. **The env file**, `/homeassistant/.crushdata/env`, one `KEY=VALUE` per line. It is read on every start, wins over the Options tab, is included in HA backups and is `chmod 600`. Only well-formed `KEY=VALUE` lines are read; anything else is skipped and logged, never executed.
2. **The Options tab.**
3. **The real container environment** (`docker run -e`, supervised installs), which has the highest precedence.

`MCP_TOKEN_*` values are exported by the add-on from each `mcp_servers` entry. Setting one by hand only matters to a fetched template that references `$MCP_TOKEN_<name>` itself.

## File locations

| Path | Purpose |
|---|---|
| `/homeassistant/.crushdata/config/crush/crushrc` | Your crushrc (fetched from the template or hand-edited) |
| `/homeassistant/.crushdata/config/crush/ollama.env` | Persisted API keys (`chmod 600`) |
| `/homeassistant/.crushdata/CRUSH.md` | Standing instructions for the agent (paths, `ha` usage, refused calls) |
| `/homeassistant/.crushdata/data/` | Crush session data |
| `/homeassistant/.crushdata/env` | Optional env-file defaults |
| `/homeassistant/.crushdata/tmux.conf` | Your tmux overrides, sourced last |

## Security notes

- The web terminal is a live shell. It is reachable only through HA ingress, so Home Assistant's own login is the boundary. ttyd listens on loopback only, and a small `socat` gate on the ingress port relays only connections from the Supervisor's ingress proxy. ttyd's `X-Hass-Source` header check stays on as a second layer. The terminal needs the default hassio bridge network (the add-on does not use `host_network`).
- The add-on has a custom AppArmor profile, no `full_access`, no Docker API, no host networking and no privileged capabilities. Toggling **Protection mode** on a single install is the escape hatch if a task truly needs more reach.
- ttyd is a pinned binary verified by sha256 at image build.
- API keys are stored in the HA config directory, so they appear in HA backups. Protect backups, and rotate keys if one leaves your control.
- Use a separate bearer token for each service; don't reuse the memory server's token elsewhere.

## Troubleshooting

- **"Choose a model" screen on first launch:** no crushrc was resolved. Check the add-on log for `[addon]` lines, set `ollama_api_key`, or confirm `crush_config_url` is reachable from the HA host.
- **`Unauthorized` errors in Crush:** the key is stale. Set `ollama_api_key` directly (it wins over everything) and restart.
- **Model missing from the picker:** confirm `crush_discover_models` is on and restart. For prices, context size or vision metadata, register the model in the crushrc.
- **`ha` command fails:** test the connection with `curl -s $HA_URL/api/ -H "Authorization: Bearer $HA_TOKEN"`.
- **Supervisor `401` / `403`:** compare with the table under [Home Assistant API access](#home-assistant-api-access); several refusals are expected. If the startup self-check shows `token DENIED` or `SUPERVISOR_TOKEN missing`, update or reinstall the add-on to get a fresh token and current permissions. Updating re-keys the add-on.
- **MCP tool errors:** the add-on log names any `mcp_servers` entry with an unreachable URL or a missing token. A `401` means that entry's token is wrong.
- **Slow responses:** the add-on never runs models; slowness usually comes from the Ollama host or provider.

## Changelog

Release notes for every version are in the add-on's **Changelog** tab (`charm-crush/CHANGELOG.md` in the repo).

## A note on AI assistance

Parts of this project — code, configuration, and documentation — were written with the help of generative AI. Everything in here was reviewed, tested, and corrected by a human before being committed; nothing was accepted on the model's say-so.

## License

MIT — see [LICENSE](LICENSE).
