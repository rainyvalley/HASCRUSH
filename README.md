# HASSCharm — Home Assistant add-ons for Charm tools

<p align="center">
  <img src="charm-crush/logo.png" alt="Crush" width="520">
</p>

Charm's terminal AI tools running inside Home Assistant, pointed at your own models and infrastructure.

**Add-on in this repo: [`charm-crush/`](charm-crush/)** — everything below documents it. Install via **Settings → Add-ons → Add-on Store → ⋮ → Repositories** → add `https://github.com/rainyvalley/HASSCharm`.

---

# HASSCrush — the Crush add-on for Home Assistant

Run [Charm Crush](https://github.com/charmbracelet/crush) — the terminal-first AI coding agent — inside Home Assistant, pointed at **your own Ollama models**, with optional shared memory.

> The ttyd-over-ingress + persistent-tmux add-on shape was inspired by [robsonfelix's claudecode add-on](https://github.com/robsonfelix/robsonfelix-hass-addons). This add-on runs Crush with your Ollama models instead.

## Features

- **Crush in the HA sidebar** — web terminal (ttyd) behind HA's own authentication; opens from the sidebar or "Open Web UI"
- **Crush in the HA sidebar** — web terminal behind HA's own authentication
- **Your models, any of them** — defaults: **GLM 5.3 Flash** daily (thinking, effort high), **GLM 5.3** deep (effort max); pick others in the TUI's `/` → model picker; refresh list = add-on restart
- **Persistent sessions** — tmux survives refresh/disconnect; crushrc + keys live in `/homeassistant/.crushdata/` (HA backups include it)
- **Central config (optional)** — fetch your crushrc from any HTTP URL each start; a fleet of machines shares one config
- **Memory (optional)** — point at any MCP memory server (e.g. the mem0 layer shared with Open WebUI); empty = off
- **`ha` CLI preinstalled and pre-authenticated** — Supervisor token env-only, never written to disk

## Requirements

- Home Assistant OS / supervised install (add-on capable)
- An Ollama endpoint: **Ollama Cloud** (ollama.com API key) and/or a **LAN Ollama** host for local/vision models

## Install

1. In HA: **Settings → Add-ons → Add-on Store → ⋮ (top right) → Repositories**, add:
   `https://github.com/rainyvalley/HASSCharm`
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
| `ollama_api_key` | *(empty)* | Ollama Cloud key (direct; wins over key URL). Same key the mem0 REST API uses when mem0 shares it |
| `ollama_key_url` | *(empty)* | HTTP URL fetching `OLLAMA_API_KEY=...` |
| `crush_large_model` | `ollama-cloud/glm-5.3-flash` | Daily default (registration id) |
| `crush_small_model` | `ollama-cloud/glm-5.3-flash` | Helper model (summaries/titles) |
| `crush_deep_model` | `ollama-cloud/glm-5.3` | Deep reasoning model (TUI picker) |
| `crush_reasoning_effort` | `high` | Daily-model thinking effort: `low`/`high`/`max` dropdown |
| `mem0_mcp_url` / `mem0_mcp_token` / `mem0_mcp_token_url` | *(empty)* | Shared memory layer (see Memory section); url empty = off |
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

**Refreshing the model list** — because the list comes from your crushrc config (not live API discovery), refresh options by editing that config. Two ways:

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

## Memory (mem0) examples

Point the add-on at any MCP memory server, or none:

| Want | Set |
|---|---|
| Shared memory with Open WebUI | `mem0_mcp_url` + `mem0_mcp_token` (or `mem0_mcp_token_url`) |
| Another MCP memory server | same two options, its URL + token |
| No memory | leave `mem0_mcp_url` empty |

**Usage from the agent**, once wired (these are the mem0-mcp-wrapper's tools; similar clients expose similar ones):

```bash
# the agent recalls automatically (server instructions tell it to search first); manually:
search_memory(query="which camera covered the greenhouse", user_id="you@example.com")
# save something durable:
add_memory(messages='[{"role":"user","content":"Trash cans go out Thursday evenings."}]', user_id="you@example.com")
# audit one memory:
memory_history(memory_id="<id from search>")
```

`user_id` matters: it's the memory space. Use the **same id in every client** (Open WebUI filter's `user_id_field=email` + crushrc defaults) and everything shares one brain.

**Multiple users on the same memory server?** Issue per-token grants on the mem0-mcp-wrapper side: `MEM0_USER_<sha256(token)[:8].upper()>=who@example.com,...` gives each bearer its own reachable spaces; then set that token (+ this add-on's `mem0_mcp_token`) per install. See the wrapper's README security notes.

## Central config (optional)

`crush_config_url` = any **plain-HTTP URL** of a crushrc text file. The natural host: another machine already running Crush (share its rc file), or any static server (Caddy, `python -m http.server`, NAS, GitHub Pages). On start the add-on fetches it; keys stay out of the template — the rc resolves secrets from the environment the add-on exports, so one template serves a fleet safely.

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

**Why there is no field for the Supervisor API key:** the Supervisor injects it itself
(`SUPERVISOR_TOKEN` env, re-exported as `HA_TOKEN`) because the add-on declares
`homeassistant_api` / `hassio_api` / `hassio_role: manager` in config.yaml. Nothing to paste,
and it re-keys on every add-on update. `401/403` denials from these APIs mean the add-on needs
an update/reinstall — except the **expected** ones (`hassio` API paths, `supervisor.*` websocket
commands, docker, admin-only endpoints), which every add-on gets denied. The agent-facing
summary ships as a "Hard Limits" block in the default `CRUSH.md` the add-on writes
(`/homeassistant/.crushdata/`), ingested by Crush on every start. Full table: the add-on's
Documentation tab (DOCS.md, *Where the Supervisor API key comes from*).

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
| `OLLAMA_API_KEY` | Ollama API Key | Ollama Cloud key (ollama.com) |
| `OLLAMA_KEY_URL` | Ollama API Key URL | URL fetching `OLLAMA_API_KEY=...` |
| `MEM0_MCP_TOKEN` | mem0 MCP Token | Bearer for the memory MCP server |
| `MEM0_MCP_TOKEN_URL` | mem0 MCP Token URL | URL fetching the token |
| `CRUSH_CONFIG_URL` | Central crushrc Template URL | HTTP URL of the shared crushrc |
| `TERM` | — | xterm-256color (set by the add-on) |

**Where to set them**

1. **The env file** — `/homeassistant/.crushdata/env`, one `KEY=VALUE` line each:

   ```bash
   OLLAMA_API_KEY=...
   MEM0_MCP_TOKEN=...
   ```

   Sourced every start; beats the Options tab; ships in HA backups; `chmod 600`.
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
  mapped folders — **no `full_access`, no Docker API, no custom AppArmor profile** (HA applies its own hardened
  default profile — the same one the official community add-ons run under). If a task
  ever needs host/docker access, toggle **Protection mode** for this add-on in Settings (per-install
  decision; raises the rating back to 1 while enabled).
- The Supervisor token (`SUPERVISOR_TOKEN`) is env-only; never written to disk or configs.
- API keys persist inside the HA config dir — included in HA backups. Protect backups accordingly,
  and rotate keys if a backup leaves your control.
- The memory layer is LAN-authenticated separately by its own bearer; don't reuse tokens across services.

## Troubleshooting

- **"Choose a model" onboarding on first launch**: no crushrc resolved — check the add-on log for `[addon]` lines. Set `ollama_api_key` or confirm `crush_config_url` is reachable from the HA host.
- **`Unauthorized` errors in crush**: stale key — set the `ollama_api_key` option directly (it wins over everything), then restart the add-on.
- **Model not in picker**: add it to the crushrc (central template or local file), restart the add-on.
- **`ha` command errors**: `HA_URL`/`HA_TOKEN` are automapped; if `ha` still fails, check the Supervisor connection with `curl -s $HA_URL/api/ -H "Authorization: Bearer $HA_TOKEN"`.
- **Supervisor API `401`/`403` denials**: no field exists for this key — the Supervisor injects `SUPERVISOR_TOKEN` itself (granted by the `homeassistant_api`/`hassio_api`/`hassio_role` flags in config.yaml). Check the add-on log's startup self-check: `Supervisor API: OK` means the key is fine and remaining denials are the expected ones (hassio paths, `supervisor.*` websocket commands, docker, admin-only endpoints — see DOCS.md). `DENIED 401/403` → update or reinstall the add-on. Profile-page long-lived tokens never work on `http://supervisor`.
- **mem0 tools error**: check the `mem0_mcp_url` is reachable from the HA host and the token is correct.
- **GPU slowness elsewhere**: this add-on never runs models; it talks to your Ollama over the network. Slowness under load usually lives in the Ollama host (shared GPU).

## License

MIT — see [LICENSE](LICENSE).