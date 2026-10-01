# Crush for Home Assistant

Run [Charm Crush](https://github.com/charmbracelet/crush) — the terminal-first AI coding agent — inside Home Assistant, pointed at **your own Ollama models** (local LAN Ollama + Ollama Cloud), with an optional shared long-term memory layer (mem0) that Open WebUI and other clients also use.

Based on the battle-tested pattern of [robsonfelix's claudecode add-on](https://github.com/robsonfelix/robsonfelix-hass-addons) (ttyd web terminal over HA ingress, persistent tmux, mapped HA directories), but running **Crush with your GLM models via Ollama** instead of Claude.

## Features

- **Crush in the HA sidebar** — web terminal in your browser, auth handled by HA ingress
- **Your GLM models**: default = GLM 5.3 Flash (thinking on, effort high); deep mode = GLM 5.3 (effort max); local vision via `qwen3-vl` on LAN Ollama
- **Persistent sessions**: tmux survives refresh/disconnect; your crushrc, session data, and API keys live in `/homeassistant/.crushdata/` (included in HA backups)
- **Central config**: fetch your crushrc from a central template each start (or use the built-in fallback config)
- **Shared memory layer**: `mem0-mcp` over HTTP (same memory Open WebUI uses)
- `ha` CLI preinstalled and pre-authenticated against the Supervisor

## Requirements

- Home Assistant OS / supervised (add-on capable install)
- An Ollama server: cloud (ollama.com API key) and/or LAN Ollama for local/vision models

## Install

1. In HA, **Settings → Add-ons → Add-on Store → ⋮ (top right) → Repositories**, add:
   `https://github.com/rainyvalley/HASSCharm`
2. Refresh; the **Crush** add-on appears. Install it.
3. Configure options (see below) — at minimum an **Ollama API Key** (or a key URL), unless your central template resolves the key itself.
4. Start the add-on; click **Open Web UI** (or the Crush entry in the sidebar).

## Options

| Option | Default | Description |
|---|---|---|
| `crush_config_url` | config server template | Fetch crushrc from a central HTTP template each start (empty = built-in fallback) |
| `ollama_api_key` | *(empty)* | Ollama Cloud API key, direct (wins over the key URL) |
| `ollama_key_url` | config server key file | Fetch the key from HTTP (plain `OLLAMA_API_KEY=...` file) |
| `mem0_mcp_url` | LAN mem0-mcp | Shared memory MCP server; empty = disabled |
| `mem0_mcp_token` / `mem0_mcp_token_url` | *(empty/URL)* | Bearer token for mem0-mcp (option wins over URL) |
| `terminal_font_size` | 14 | Web terminal font size (10–24) |
| `terminal_theme` | dark | dark / light |
| `working_directory` | `/homeassistant` | Where crush starts |
| `session_persistence` | true | tmux session survives disconnects |
| `auto_update_crush` | true | Update crush on add-on start (with rollback) |

## File locations (inside the add-on)

- `/homeassistant/.crushdata/config/crush/crushrc` — your crushrc (persistent)
- `/homeassistant/.crushdata/config/crush/ollama.env` — persisted API keys (chmod 600)
- `/homeassistant/.crushdata/CRUSH.md` — generated standing instructions (path mapping, ha CLI usage, log levels)
- `/homeassistant/.crushdata/tmux.conf` — user tmux overrides (optional; sourced last)

## Usage

- Open from the sidebar (Crush). The web terminal attaches to a persistent tmux session (`crush`).
- `ha` CLI is preauthenticated (`HA_TOKEN`/`HA_URL` env); crush reads config files directly.
- Ask away: "show me failing automations", "check core logs for errors", "create an automation that flashes the kitchen light when the laundry finishes".

## Security

- The add-on runs as root with `full_access` (like the reference claudecode add-on) to allow file/config management and the Docker/Supervisor APIs.
- The Supervisor token is exported into the environment only; it's never written to disk.
- API keys live in `/homeassistant/.crushdata/config/crush/ollama.env` (chmod 600) — the token file is inside the HA config dir, so it's present in HA **backups**. Keep HA backups safe accordingly.
- The mem0 MCP layer requires its own bearer token; the shared memory layer is LAN-authenticated separately.

## Troubleshooting

- **"choose a model" onboarding on first launch**: no crushrc resolved — check the add-on log for `[addon]` lines; set `crush_config_url` or the Ollama API key option.
- **Unauthorized errors**: the persisted key changed; set the `ollama_api_key` option directly (it wins over everything).
- **`ha` command fails**: check `HA_URL`/`HA_TOKEN` env (should never happen; it's automapped by Supervisor).
- **No GPU**: this add-on talks to Ollama over the network — Ollama's own host owns the GPU.

## License

MIT — see [LICENSE](../LICENSE).