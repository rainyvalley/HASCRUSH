#!/bin/bash
# Crush add-on startup: config fetch + key resolution + persistence + ttyd.
set -e

HA_TOKEN="${SUPERVISOR_TOKEN:-}"; export HA_TOKEN
export HA_URL="http://supervisor/core"

PERSIST_DIR=/homeassistant/.crushdata
mkdir -p "$PERSIST_DIR/config/crush" "$PERSIST_DIR/data" /root/.config /root/.local/share
chmod 700 "$PERSIST_DIR" 2>/dev/null || true

# ── Optional env-file defaults ─────────────────────────────────────────
# /homeassistant/.crushdata/env (KEY=VALUE lines) sets DEFAULTS via environment
# variables — the script's own `VAR=${VAR:-...}` chains honor it everywhere.
# Precedence: real environment (docker run -e / HA env) > this file > add-on
# option > central URL > persisted file. Example lines:
#   OLLAMA_API_KEY=sk-...
#   MEM0_MCP_TOKEN=...
#   CRUSH_CONFIG_URL=http://my-server/crushrc.template
# Missing file = no defaults set; everything still works from options/schema.
ENV_FILE="$PERSIST_DIR/env"
if [ -r "$ENV_FILE" ]; then
  # Only KEY=VALUE and export KEY=VALUE lines are honored - anything else
  # (shell code, pipes, command substitution) is refused, so a stray line can
  # never execute as code at startup.
  BAD=$(grep -vE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*="?[A-Za-z0-9_./:@+%-]*"?[[:space:]]*(#.*)?$' "$ENV_FILE" || true)
  if [ -n "$BAD" ]; then
    echo "[addon][WARN] $ENV_FILE has non KEY=VALUE lines - they were NOT executed:" >&2
    echo "$BAD" >&2 | sed 's/^/    /'
  fi
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  echo "[addon] env defaults sourced from $ENV_FILE"
fi

# ── Persistence symlinks ────────────────────────────────────────────────
# Everything crush writes lives in /homeassistant/.crushdata/ so it survives
# container restarts, rebuilds and reinstalls (and ships inside HA backups).
rm -rf /root/.config/crush
ln -sfn "$PERSIST_DIR/config/crush" /root/.config/crush
rm -rf /root/.local/share/crush
ln -sfn "$PERSIST_DIR/data" /root/.local/share/crush

# ── CRUSH.md: standing instructions for the agent ──────────────────────
# Written ONCE; user edits persist (delete the file to get a fresh default).
if [ ! -f "$PERSIST_DIR/CRUSH.md" ]; then
cat > "$PERSIST_DIR/CRUSH.md" <<'EOF'
# Crush - Home Assistant Add-on

## Path Mapping

In this add-on container, paths map differently than HA Core:
- `/homeassistant` = HA config directory (equivalent to `/config` in HA Core)
- `/config` does NOT exist - always use `/homeassistant`

When users mention `/config/...`, translate to `/homeassistant/...`

## Home Assistant Integration

Use the `ha` CLI (token + URL already set in the environment):
- `ha core logs 2>&1 | tail -100`        - recent logs
- `ha core logs 2>&1 | grep -i keyword`  - filter logs
- `ha core stats` / `ha host info`       - system status

Automation and configuration files live in /homeassistant
(automations.yaml, configuration.yaml, scripts.yaml, ...).

## Available Paths

| Path | Description | Access |
|------|-------------|--------|
| `/homeassistant` | HA configuration | read-write |
| `/share` | Shared folder | read-write |
| `/media` | Media files | read-write |
| `/ssl` | SSL certificates | read-only |
| `/backup` | Backups | read-only |

Log levels: `debug` < `info` < `warning` < `error`. `_LOGGER.debug()` output
is invisible unless debug logging is enabled in configuration.yaml.
EOF
fi

# ── crushrc: central template, or a self-contained fallback ────────────
crushrc="$PERSIST_DIR/config/crush/crushrc"
CONFIG_URL="${CRUSH_CONFIG_URL:-$(jq -r '.crush_config_url // ""' /data/options.json)}"
if [ -n "$CONFIG_URL" ] \
   && curl -fsSL --max-time 10 "$CONFIG_URL" -o /tmp/crushrc.new 2>/dev/null \
   && head -c 2000 /tmp/crushrc.new | grep -qE '(provider|model) (add|large|small)|crushrc'; then
  mkdir -p "$(dirname "$crushrc")"
  mv -f /tmp/crushrc.new "$crushrc"   # same-dir move = atomic
  echo "[addon] crushrc fetched from the central template: $CONFIG_URL"
else
  if [ ! -f "$crushrc" ]; then
    cat > "$crushrc" <<'RCEOF'
# Built-in fallback crushrc (add-on). Set crush_config_url to manage centrally.

# Key resolution: addon option/env -> persisted file
OLLAMA_API_KEY="${OLLAMA_API_KEY:-$(jq -r '.ollama_api_key // ""' /data/options.json 2>/dev/null)}"
: "${OLLAMA_API_KEY:-$(grep -m1 -s '^OLLAMA_API_KEY=' "$HOME/.config/crush/ollama.env" 2>/dev/null | cut -d= -f2)}"
export OLLAMA_API_KEY
: "${OLLAMA_API_KEY:?set the Ollama API key add-on option, or put OLLAMA_API_KEY=... in ~/.config/crush/ollama.env}"

provider add ollama-cloud --type openai-compat --base-url "https://ollama.com/v1" --api-key "$OLLAMA_API_KEY"
if [ -n "$LOCAL_OLLAMA_URL" ]; then
provider add ollama-local --type ollama --base-url "$LOCAL_OLLAMA_URL"
fi

# Default = GLM 5.3 Flash with thinking (effort high = model-decided depth)
model add ollama-cloud/glm-5.3-flash --name "GLM 5.3 Flash" --context-window 1048576 --default-max-tokens 131072 --can-reason true --reasoning-effort high --price-input 0.15 --price-output 0.5
model large ollama-cloud/glm-5.3-flash --reasoning-effort high
model small ollama-cloud/glm-5.3-flash --reasoning-effort high

# Deep mode (registered, not default - pick it via / in the TUI):
model add ollama-cloud/glm-5.3 --name "GLM 5.3" --context-window 1000000 --default-max-tokens 128000 --can-reason true --reasoning-effort max --price-input 1.4 --price-output 4.4

# Local vision (LAN Ollama) + cloud vision fallback
if [ -n "$LOCAL_OLLAMA_URL" ]; then
model add ollama-local/qwen3-vl:4b-instruct --context-window 8192 --supports-images true --name "Qwen3 VL 4B (local vision)"
fi
model add ollama-cloud/gemma4:31b --context-window 128000 --supports-images true --name "Gemma 4 31B (cloud vision)"

option notifications auto

RCEOF
    echo "[addon] built-in fallback crushrc written (set crush_config_url to manage centrally)"
  else
    echo "[addon] keeping existing crushrc (central template unreachable)"
  fi
fi

# ── LLM provider: ollama (default) or a 3rd-party OpenAI-compatible API ─
PROVIDER=$(jq -r '.provider // "ollama"' /data/options.json)
if [ "$PROVIDER" = "third_party" ]; then
  TP_URL="${THIRD_PARTY_BASE_URL:-$(jq -r '.third_party_base_url // ""' /data/options.json)}"
  TP_KEY="${THIRD_PARTY_API_KEY:-$(jq -r '.third_party_api_key // ""' /data/options.json)}"
  if [ -z "$TP_URL" ] || [ -z "$TP_KEY" ]; then
    echo "[addon][ERROR] provider=third_party but third_party_base_url / third_party_api_key are missing - falling back to ollama"
  else
    TPID=openai-compat-3p
    sed -iE "s#provider add ollama-cloud#provider add $TPID#; s#ollama-cloud/#$TPID/#g" "$crushrc"
    sed -i "s#--base-url \"https://ollama.com/v1\"#--base-url \"$TP_URL\"#" "$crushrc"
    # the key stays as --api-key "$OLLAMA_API_KEY" in the rc; we export the
    # third-party key as OLLAMA_API_KEY below (no sed on key values: they can
    # contain any character)
    export OLLAMA_API_KEY="$TP_KEY"
    echo "[addon] provider=third_party: models remapped to $TPID ($TP_URL)"
  fi
fi

# ── Ollama API key: option -> central key URL -> existing file ─────────
keyfile="$PERSIST_DIR/config/crush/ollama.env"
OPT_KEY="${OLLAMA_API_KEY:-$(jq -r '.ollama_api_key // ""' /data/options.json)}"
KEY_URL="${OLLAMA_KEY_URL:-$(jq -r '.ollama_key_url // ""' /data/options.json)}"
touch "$keyfile"; chmod 600 "$keyfile"
if [ -n "$OPT_KEY" ]; then
  # addon option wins; rewrite the key file DELIBERATELY (not sed: keys may
  # contain '/', '#' or other sed-specials which would corrupt s/// expressions)
  { grep -v '^OLLAMA_API_KEY=' "$keyfile" || true; printf 'OLLAMA_API_KEY=%s\n' "$OPT_KEY"; } > "$keyfile.tmp"
  mv "$keyfile.tmp" "$keyfile"
  chmod 600 "$keyfile"
  echo "[addon][INFO] ollama API key set (env/env-file/option)"
elif [ -n "$KEY_URL" ] && curl -fsSL --max-time 10 "$KEY_URL" -o /tmp/key.new 2>/dev/null \
     && grep -q '^OLLAMA_API_KEY=' /tmp/key.new; then
  CENTRAL=$(grep -m1 '^OLLAMA_API_KEY=' /tmp/key.new)
  LOCAL=$(grep -m1 -s '^OLLAMA_API_KEY=' "$keyfile" || true)
  if [ "$CENTRAL" != "$LOCAL" ]; then
    { grep -v '^OLLAMA_API_KEY=' "$keyfile" 2>/dev/null || true; echo "$CENTRAL"; } > "$keyfile.tmp"
    mv "$keyfile.tmp" "$keyfile"
    echo "[addon][INFO] ollama API key refreshed from $KEY_URL"
  fi
else
  [ -s "$keyfile" ] && echo "[addon][INFO] using existing persisted ollama key" \
    || echo "[addon][WARN] no ollama API key found (option, key URL, or persisted file)"
fi
# mem0 token: option -> token URL (no key file needed; it is passed via the crushrc below)
MEM0_MCP_TOKEN="${MEM0_MCP_TOKEN:-$(jq -r '.mem0_mcp_token // ""' /data/options.json)}"
MTOK_URL="${MEM0_MCP_TOKEN_URL:-$(jq -r '.mem0_mcp_token_url // ""' /data/options.json)}"
if [ -z "$MEM0_MCP_TOKEN" ] && [ -n "$MTOK_URL" ]; then
  MEM0_MCP_TOKEN=$(curl -fsSL --max-time 10 "$MTOK_URL" 2>/dev/null | tr -d '[:space:]')
fi
export MEM0_MCP_TOKEN

# mem0 MCP url: optional shared-memory layer (empty = no mem0 in crush)
# - unset url           : scrub any mem0 line (operator turned memory OFF)
# - url but no token    : skip mem0 (would 401 forever) + warn
# - url and token       : rewrite/append the mcp add mem0 line with both
MEM0_URL=$(jq -r '.mem0_mcp_url // ""' /data/options.json)
if [ -z "$MEM0_URL" ]; then
  sed -i '/mcp add mem0 /d' "$crushrc" 2>/dev/null || true
elif [ -z "$MEM0_MCP_TOKEN" ]; then
  echo "[addon][WARN] mem0_mcp_url set but no token found - mem0 MCP skipped"
  sed -i '/mcp add mem0 /d' "$crushrc" 2>/dev/null || true
else
  if grep -q "mcp add mem0" "$crushrc" 2>/dev/null; then
    sed -i "s#mcp add mem0 .*#mcp add mem0 --type http --url \"$MEM0_URL\" --header Authorization \"Bearer \$MEM0_MCP_TOKEN\"#" "$crushrc"
  else
    printf '\nmcp add mem0 --type http --url "%s" --header Authorization "Bearer $MEM0_MCP_TOKEN"\n' "$MEM0_URL" >> "$crushrc"
  fi
fi

# ── Model defaults from options/env (apply to fetched or fallback rc) ──
# CRUSH_LARGE_MODEL / CRUSH_SMALL_MODEL / CRUSH_DEEP_MODEL / CRUSH_REASONING_EFFORT envs or the
# matching add-on options rewire the slots to whatever the operator picked; unknown/skipped values
# leave the config's own slots in place.
apply_model_slot() {
  # $1 = slot (large|small), $2 = chosen model id ("" = keep config's choice).
  # Replaces ONLY the model id, preserving any trailing flags (effort etc.).
  [ -n "$2" ] || return 0
  if grep -qE "^model $1 " "$crushrc" 2>/dev/null; then
    sed -i "s#^model $1 [^ ]*#model $1 $2#" "$crushrc"
  else
    printf '\nmodel %s %s\n' "$1" "$2" >> "$crushrc"
  fi
}
LARGE_MODEL="${CRUSH_LARGE_MODEL:-$(jq -r '.crush_large_model // ""' /data/options.json)}"
SMALL_MODEL="${CRUSH_SMALL_MODEL:-$(jq -r '.crush_small_model // ""' /data/options.json)}"
DEEP_MODEL="${CRUSH_DEEP_MODEL:-$(jq -r '.crush_deep_model // ""' /data/options.json)}"
EFFORT="${CRUSH_REASONING_EFFORT:-$(jq -r '.crush_reasoning_effort // ""' /data/options.json)}"
apply_model_slot large "$LARGE_MODEL"
apply_model_slot small "$SMALL_MODEL"
# deep model: register if not already registered (escaped, busybox-safe grep)
if [ -n "$DEEP_MODEL" ]; then
  ESC=$(printf '%s' "$DEEP_MODEL" | sed 's/[.[\\*+^$()|?{]/\\&/g')
  grep -qE "^model add .*/$ESC( |$)" "$crushrc" 2>/dev/null || \
    printf '\nmodel add %s --can-reason true --reasoning-effort max\n' "$DEEP_MODEL" >> "$crushrc"
fi

if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low|high|max)
      # strip existing effort flags from the DAILY slot lines only, then append
      # the chosen effort (busybox-safe: no backreferences, line-targeted)
      for _slot in large small; do
        _line=$(grep -E "^model ${_slot} " "$crushrc" | head -1 || true)
        [ -n "$_line" ] || continue
        _clean=$(printf '%s\n' "$_line" | sed "s/[[:space:]]*--reasoning-effort [a-z]*//")
        sed -i "s#^${_line}\$#${_clean} --reasoning-effort ${EFFORT}#" "$crushrc" 2>/dev/null || true
      done
      ;;
    *)
      echo "[addon][WARN] crush_reasoning_effort: '$EFFORT' not low|high|max - ignored"
      ;;
  esac
fi
[ -n "$LARGE_MODEL$SMALL_MODEL$DEEP_MODEL$EFFORT" ] && echo "[addon] model defaults applied from options/env"

# NOTE for crushrc users: the crushrc is BASH - it resolves OLLAMA_API_KEY and
# MEM0_MCP_TOKEN from the environment (exported above), so the fetched central
# template keeps working without the addon knowing its internals.

# ── crush sanity + version banner ──────────────────────────────────────
BUILT_VERSION=$(cat /etc/crush-version 2>/dev/null || echo unknown)
if crush --version < /dev/null >/dev/null 2>&1; then
  echo "[addon] crush binary OK ($BUILT_VERSION built in)"
else
  echo "[addon][ERROR] crush binary not responding - terminal still starts for debugging"
fi

AUTO_UPDATE=$(jq -r '.auto_update_crush // false' /data/options.json)
if [ "$AUTO_UPDATE" = "true" ]; then
  NEW_VER=$(curl -fsSL --max-time 15 https://api.github.com/repos/charmbracelet/crush/releases/latest 2>/dev/null | jq -r .tag_name | tr -d v)
  if [ -n "$NEW_VER" ] && [ "$NEW_VER" != "$BUILT_VERSION" ]; then
    ARCH=$(uname -m); case "$ARCH" in x86_64) A=x86_64;; aarch64) A=aarch64;; *) A=?;; esac
    curl -fsSL --max-time 30 "https://github.com/charmbracelet/crush/releases/download/v${NEW_VER}/crush_${NEW_VER}_${A}.tar.gz" -o /tmp/crush.upd 2>/dev/null \
    && tar -xzf /tmp/crush.upd -C /usr/local/bin crush \
    && chmod +x /usr/local/bin/crush && rm -f /tmp/crush.upd \
    && (crush --version < /dev/null >/dev/null 2>&1 || { echo "[addon][WARN] updated crush fails; rolling back"; \
         curl -fsSL --max-time 30 "https://github.com/charmbracelet/crush/releases/download/v${BUILT_VERSION}/crush_${BUILT_VERSION#v}_${A}.tar.gz" -o /tmp/crush.rb \
         && tar -xzf /tmp/crush.rb -C /usr/local/bin crush; rm -f /tmp/crush.rb; }) \
    && echo "[addon] crush updated to $NEW_VER"
  else
    echo "[addon] crush $BUILT_VERSION is current"
  fi
fi

# ── Web terminal ────────────────────────────────────────────────────────
FONT_SIZE=$(jq -r '.terminal_font_size // 14' /data/options.json)
THEME=$(jq -r '.terminal_theme // "dark"' /data/options.json)
SESSION_PERSIST=$(jq -r 'if .session_persistence == null then true else .session_persistence end' /data/options.json)
WORKDIR=$(jq -r '.working_directory // "/homeassistant"' /data/options.json)
if [ "$THEME" = "dark" ]; then
  COLORS='background=#1e1e2e,foreground=#cdd6f4,cursor=#f5e0dc'
else
  COLORS='background=#eff1f5,foreground=#4c4f69,cursor=#dc8a78'
fi
if [ "$SESSION_PERSIST" = "true" ]; then
  SHELL_CMD='tmux new-session -A -s crush'
else
  SHELL_CMD='bash --login'
fi
cd "$WORKDIR" 2>/dev/null || cd /homeassistant

exec ttyd --port 7681 --writable --ping-interval 30 --max-clients 5 \
    -t fontSize=$FONT_SIZE \
    -t fontFamily=Monaco,Consolas,monospace \
    -t scrollback=20000 \
    -t "theme=$COLORS" \
    $SHELL_CMD