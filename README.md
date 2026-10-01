# HASSCharm — Home Assistant add-ons for Charm tools

Charm's terminal AI tools running inside Home Assistant, pointed at your own models and infrastructure.

**Add-on in this repo: [`charm-crush/`](charm-crush/)** — everything below documents it. Install via **Settings → Add-ons → Add-on Store → ⋮ → Repositories** → add `https://github.com/rainyvalley/HASSCharm`.

---

# Crush for Home Assistant

Run [Charm Crush](https://github.com/charmbracelet/crush) — the terminal-first AI coding agent — inside Home Assistant, pointed at **your own Ollama models** (local LAN Ollama + Ollama Cloud), with an optional shared long-term memory layer you can plug in or leave out.

> The ttyd-over-ingress + persistent-tmux add-on shape was inspired by [robsonfelix's claudecode add-on](https://github.com/robsonfelix/robsonfelix-hass-addons). This add-on runs Crush with your Ollama models instead.

## Features

- **Crush in the HA sidebar** — web terminal (ttyd) behind HA's own authentication; opens from the sidebar or "Open Web UI"
- **Your models**: any model registered in your Ollama (local + Ollama Cloud). Defaults are GLM-family: `GLM 5.3 Flash` for daily chat (thinking on, effort high) and `GLM 5.3` for deep mode (effort max); swap models in the TUI's `/` → model picker anytime
- **Persistent sessions**: tmux survives refresh/disconnect; crushrc, API keys, and session data live in `/homeassistant/.crushdata/` (which HA backs up)
- **Central config (optional)**: each start can fetch your crushrc from any HTTP URL — that's how a whole fleet of machines (HA devices, workstations) shares one config
- **Memory (optional)**: point it at any MCP memory server — e.g. the shared mem0 layer used by Open WebUI, or your own — so HA-side Crush remembers the same facts your other tools know
- **Model picker defaults** (shown in the TUI and in this repo's fallback config): **GLM 5.3 Flash** (large + small slots, thinking on at effort high) and **GLM 5.3** for deep work (effort max). Choose anything else in the TUI `/` → model picker; add your own models via the central template or the local crushrc (refresh = add-on restart).
- `ha` CLI preinstalled and pre-authenticated against the Supervisor API; `HA_TOKEN`/`HA_URL` exported to the environment only

## Requirements

- Home Assistant OS / supervised install (add-on capable)
- An Ollama endpoint: **Ollama Cloud** (ollama.com API key) and/or a **LAN Ollama** host for local/vision models

## Install

1. In HA: **Settings → Add-ons → Add-on Store → ⋮ (top right) → Repositories**, add:
   `https://github.com/rainyvalley/HASSCharm`
2. Refresh the store; install **Crush**.
3. Configure options (see below) — at minimum an **Ollama API Key** (or a key URL), unless your config template resolves the key itself.
4. Start the add-on; open it from the sidebar (panel title "Crush").

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

Memory is **optional** and decoupled: it's one extra MCP server the wrapper never hardcodes. The defaults point at your LAN mem0 layer, or set anything else:

| Use case | Options to set |
|---|---|
| Shared memory with Open WebUI (mem0-mcp-wrapper on your LAN) | `mem0_mcp_url=http://<host>:8300/mcp`, `mem0_mcp_token=<its bearer>` (or `mem0_mcp_token_url` pointing at the token file) |
| A different/own memory server (`mem0ai` cloud via a wrapper, OpenMemory, or any MCP memory server) | same two options, its URL + its token |
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

## Central config: hosted by anyone

The `crush_config_url` is **plain HTTP** — any static file server works. It's a single text file (the crushrc) fetched at add-on start. No auth, no API — host it however:

- **The author's personal server** — the default URLs point at one (`http://203.0.113.10:8887/...` on the author's LAN). Your install should replace those URLs with your own (or leave them and accept the defaults won't resolve outside that network — the built-in fallback config covers it).
- **DIY with nginx in a container** (2 minutes):

  ```bash
  mkdir -p /srv/crush-shared
  cat > /srv/crush-shared/crushrc <<'EOF'
  provider add ollama-cloud --type openai-compat \
    --base-url "https://ollama.com/v1" --api-key "$OLLAMA_API_KEY"
  model add ollama-cloud/glm-5.3-flash --name "GLM 5.3 Flash" --context-window 1048576 \
    --default-max-tokens 131072 --can-reason true --reasoning-effort high
  model large ollama-cloud/glm-5.3-flash --reasoning-effort high
  model small ollama-cloud/glm-5.3-flash --reasoning-effort high
  EOF
  docker run -d --name crush-config -p 8887:80 \
    -v /srv/crush-shared:/usr/share/nginx/html:ro nginx:alpine
  # in the add-on: crush_config_url = http://<that-host>:8887/crushrc
  ```

  or any existing box: python -m http.server, Caddy, a NAS share served over HTTP, GitHub Pages/any URL reachable from HA.

- **How keys fit central configs**: the crushrc is real Bash; resolve secrets from the ENV (the add-on exports `OLLAMA_API_KEY` from its options before running crushrc), NOT inline in the template — that keeps one shared template safe for a fleet while keys stay per-machine. The add-on also persists resolved keys to `~/.config/crush/ollama.env` (chmod 600), which survives restarts and stays out of the template file.

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

## Environment variables

Every option can be set as an environment variable instead of (or in priority above) the add-on
Options tab. **Precedence: real environment > `/homeassistant/.crushdata/env` file > Options tab
value > central URL > persisted file.**

| Env var | Matches option | Notes |
|---|---|---|
| `OLLAMA_API_KEY` | Ollama API Key | Ollama Cloud key (ollama.com) |
| `OLLAMA_KEY_URL` | Ollama API Key URL | URL fetching `OLLAMA_API_KEY=...` |
| `MEM0_MCP_TOKEN` | mem0 MCP Token | Bearer for the memory MCP server |
| `MEM0_MCP_TOKEN_URL` | mem0 MCP Token URL | URL fetching the token |
| `CRUSH_CONFIG_URL` | Central crushrc Template URL | HTTP URL of the shared crushrc |
| `TERM` | — | xterm-256color (set by the add-on) |

**Three ways to set them**

1. **The env file (recommended inside HA)** — create
   `/homeassistant/.crushdata/env` in the add-on's web terminal (or the file editor), one
   `KEY=VALUE` per line:

   ```bash
   OLLAMA_API_KEY=sk-...
   MEM0_MCP_TOKEN=...
   CRUSH_CONFIG_URL=http://my-server:8887/crushrc.template
   ```

   It is sourced (shell-syntax, `set -a`) on every add-on start, survives restarts/rebuilds, ships
   in HA backups, and **wins over the Options tab** — handy for secrets you don't want shown in the
   options UI. `chmod 600` it.
2. **The Options tab** — plain values; each one also lands in `/data/options.json`, and secrets
   there are replaced into the env chain unless a higher-precedence value exists.
3. **Real environment (supervised/docker users only)** — HAOS users cannot set container env
   directly; but on a supervised install running the add-on image yourself:
   `docker run -e OLLAMA_API_KEY=... ...`. Real env beats the file and the tab.

**API-key-related envs behave the same way** — the crushrc is Bash, so `OLLAMA_API_KEY`,
`MEM0_MCP_TOKEN`, and any custom value live in the same namespace; a fetched central template
resolves its secrets from these envs (never inline), keeping the template fleet-safe.

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

- The add-on runs as root with `full_access` (file/config management + Supervisor/Docker APIs) because Crush is a full terminal agent.
- The Supervisor token (`SUPERVISOR_TOKEN`) is env-only; never written to disk or into configs.
- API keys persist in the HA config dir — meaning they're included in HA backups. Protect HA backups accordingly, and rotate keys if a backup leaves your control.
- The memory layer is LAN-authenticated separately by its own bearer; don't reuse tokens across services.

## Troubleshooting

- **"Choose a model" onboarding on first launch**: no crushrc resolved — check the add-on log for `[addon]` lines. Set `ollama_api_key` or confirm `crush_config_url` is reachable from the HA host.
- **`Unauthorized` errors in crush**: stale key — set the `ollama_api_key` option directly (it wins over everything), then restart the add-on.
- **Model not in picker**: add it to the crushrc (central template or local file), restart the add-on.
- **`ha` command errors**: `HA_URL`/`HA_TOKEN` are automapped; if `ha` still fails, check the Supervisor connection with `curl -s $HA_URL/api/ -H "Authorization: Bearer $HA_TOKEN"`.
- **mem0 tools error**: check the `mem0_mcp_url` is reachable from the HA host and the token is correct.
- **GPU slowness elsewhere**: this add-on never runs models; it talks to your Ollama over the network. Slowness under load usually lives in the Ollama host (shared GPU).

## License

MIT — see [LICENSE](LICENSE).