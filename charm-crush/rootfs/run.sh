#!/bin/bash
# Crush add-on startup: config fetch + key resolution + persistence + ttyd.
set -e

# Tell s6-overlay to keep the container environment (it strips it by default)
export S6_KEEP_ENV=1

HA_TOKEN="${SUPERVISOR_TOKEN:-}"; export HA_TOKEN
export HA_URL="http://supervisor/core"

# s6-overlay-suexec strips the container environment when it re-execs the
# service stack; tmux/bash/crush then see an empty $HOME and abort with
# "Failed to get user home directory". Re-pin the basics here (and let s6
# keep the whole env below).
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export SHELL="${SHELL:-/bin/bash}"

# ── Supervisor API self-check: make denials visible at startup ──────────
# SUPERVISOR_TOKEN is injected by the Supervisor itself (never by the user);
# the hassio_api / homeassistant_api flags in config.yaml grant its reach.
# One test call each so a denial shows up in the add-on log with a cause,
# instead of as bare 401s later - there is no option field for this key,
# only these flags (update/reinstall the add-on if they ever 401/403).
if [ -z "$HA_TOKEN" ]; then
  echo "[addon][WARN] SUPERVISOR_TOKEN missing - HA/supervisor API calls will 401 (update or reinstall the add-on so the Supervisor issues its key)"
else
  SUP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $HA_TOKEN" http://supervisor/info || true)
  case "$SUP_CODE" in
    200) echo "[addon] Supervisor API: OK (token accepted, manager role)" ;;
    401) echo "[addon][WARN] Supervisor API: token DENIED 401 (invalid/re-keyed) - update or reinstall the add-on" ;;
    403) echo "[addon][WARN] Supervisor API: access DENIED 403 (role/permission) - hassio_api/hassio_role not granted; update the add-on" ;;
    *)   echo "[addon][WARN] Supervisor API: unreachable (HTTP ${SUP_CODE:-none}) - Supervisor restarting or DNS issue" ;;
  esac
  CORE_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $HA_TOKEN" http://supervisor/core/api/ || true)
  case "$CORE_CODE" in
    200) echo "[addon] HA Core API: OK (homeassistant_api granted)" ;;
    401) echo "[addon][WARN] HA Core API: token DENIED 401 - homeassistant_api not active; update the add-on" ;;
    *)   echo "[addon][WARN] HA Core API: not reachable (HTTP ${CORE_CODE:-none}) - normal while HA Core is still starting" ;;
  esac
fi

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
# Crush ingests this file from its working directory on every start, so it is
# the agent's default guardrail: what is pre-wired (ask for no keys) and which
# denials are expected. Written ONCE; user edits persist (delete the file to
# get a fresh default). Pre-1.0.12 installs lack the limits block - inject it
# between the markers without touching their edits.
CRUSH_MD="$PERSIST_DIR/CRUSH.md"
LIMITS_START='<!-- hasscrush-limits-start -->'
LIMITS_END='<!-- hasscrush-limits-end -->'
LIMITS_BODY='<!-- hasscrush-limits-start -->
## Hard Limits (pre-wired - ask for none, do not retry denials)

| Thing | Status |
|---|---|
| Supervisor API key | ALREADY in the environment (`HA_TOKEN` = `SUPERVISOR_TOKEN`, injected by HA). Never ask the user for a key. |
| HA Core API key | same token, `${HA_URL}/api/...` works as-is |
| LAN Ollama / mem0 | pre-wired by the crushrc - nothing to configure |

NEVER attempt or retry these - they are denied BY DESIGN; one try at most,
then report to the user instead:
- `http://supervisor/hassio/...` or `${HA_URL}/api/hassio/...` -> 403 (blacklisted for every add-on)
- websocket `supervisor.*`/`hassio.*` commands -> `unauthorized` (blocked since Supervisor 2026.08) - use the `ha` CLI or REST
- `/os/ssh/authorized_keys`, `/addons/<slug>/security` -> admin-only; this add-on is manager
- docker CLI -> no docker socket; the USER may toggle Protection mode if ever needed
- Profile-page long-lived tokens do NOT work on `http://supervisor`

Safe alternatives: `ha` CLI (pre-authed: `ha core logs`, `ha core stats`,
`ha host info`, `ha addons`), REST with `$HA_TOKEN` (`${HA_URL}/api/states/...`,
`${HA_URL}/api/services/...`), and plain files under the mapped paths.
<!-- hasscrush-limits-end -->'
inject_limits() {
  # only when the markers are absent; never duplicate into edited files
  grep -qF "$LIMITS_START" "$CRUSH_MD" && return 0
  if grep -q '^##' "$CRUSH_MD"; then
    line=$(grep -n '^##' "$CRUSH_MD" | head -1 | cut -d: -f1)
    head -n $((line-1)) "$CRUSH_MD" > "$CRUSH_MD.tmp"
    printf '%s\n' "$LIMITS_BODY" >> "$CRUSH_MD.tmp"
    tail -n +$line "$CRUSH_MD" >> "$CRUSH_MD.tmp"
  else
    { cat "$CRUSH_MD"; printf '\n%s\n' "$LIMITS_BODY"; } > "$CRUSH_MD.tmp"
  fi
  mv "$CRUSH_MD.tmp" "$CRUSH_MD"
  echo "[addon] hard-limits guardrails injected into $CRUSH_MD"
}
if [ ! -f "$CRUSH_MD" ]; then
cat > "$CRUSH_MD" <<EOF
# Crush - Home Assistant Add-on

$LIMITS_BODY

## Path Mapping

In this add-on container, paths map differently than HA Core:
- \`/homeassistant\` = HA config directory (equivalent to \`/config\` in HA Core)
- \`/config\` does NOT exist - always use \`/homeassistant\`

When users mention \`/config/...\`, translate to \`/homeassistant/...\`

## Home Assistant Integration

Use the \`ha\` CLI (token + URL already set in the environment):
- \`ha core logs 2>&1 | tail -100\`        - recent logs
- \`ha core logs 2>&1 | grep -i keyword\`  - filter logs
- \`ha core stats\` / \`ha host info\`       - system status

Automation and configuration files live in /homeassistant
(automations.yaml, configuration.yaml, scripts.yaml, ...).

## Available Paths

| Path | Description | Access |
|------|-------------|--------|
| \`/homeassistant\` | HA configuration | read-write |
| \`/share\` | Shared folder | read-write |
| \`/media\` | Media files | read-write |
| \`/ssl\` | SSL certificates | read-only |
| \`/backup\` | Backups | read-only |

Log levels: \`debug\` < \`info\` < \`warning\` < \`error\`. \`_LOGGER.debug()\` output
is invisible unless debug logging is enabled in configuration.yaml.
EOF
else
  inject_limits
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

# Key resolution: environment -> addon option -> persisted file.
# NOTE the classic bug fixed here: `: "${VAR:-cmd}"` does NOT assign!
[ -n "$OLLAMA_API_KEY" ] || OLLAMA_API_KEY="$(jq -r '.ollama_api_key // ""' /data/options.json 2>/dev/null)"
[ -n "$OLLAMA_API_KEY" ] || OLLAMA_API_KEY="$(grep -m1 -s '^OLLAMA_API_KEY=' "$HOME/.config/crush/ollama.env" 2>/dev/null | cut -s -d= -f2)"
export OLLAMA_API_KEY
[ -n "$OLLAMA_API_KEY" ] || { echo "ERROR: FAILED - no Ollama API key. Set the add-on option
or put OLLAMA_API_KEY=... in ~/.config/crush/ollama.env (home is not
defined without it)."; exit 1; }

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
    # migrate old fallback rcs written before the ':?'-no-assign fix
    if grep -q '^: "${OLLAMA_API_KEY:?' "$crushrc" 2>/dev/null; then
      sed -i '/^: "${OLLAMA_API_KEY:?/d' "$crushrc"
      echo "[addon] migrated existing crushrc (key assignment bug fixed)"
    fi
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
# mem0 MCP via the legacy mem0_mcp_* options (or mcp_servers entries named
# mem0): the token env may come from any of the option/name-specific vars set
# below, so export each only when the generated rc actually references it.
# Legacy fields stay additive-compatible with the mcp_servers merge.
MEM0_MCP_TOKEN="${MEM0_MCP_TOKEN:-$(jq -r '.mem0_mcp_token // ""' /data/options.json)}"
MTOK_URL="${MEM0_MCP_TOKEN_URL:-$(jq -r '.mem0_mcp_token_url // ""' /data/options.json)}"
if [ -z "$MEM0_MCP_TOKEN" ] && [ -n "$MTOK_URL" ]; then
  MEM0_MCP_TOKEN=$(curl -fsSL --max-time 10 "$MTOK_URL" 2>/dev/null | tr -d '[:space:]')
fi
export MEM0_MCP_TOKEN
MCP_TOKENS_EXPORTED=0
mcp_remove() {
  # Idempotency guard: drop any existing entry registering MCP server $1 so
  # option rewrites never stack duplicates on repeated starts. Two traps this
  # guards against:
  #  - crushrc entries span MULTIPLE LINES (backslash continuations); deleting
  #    only the first line orphans the continuations as junk bash and mangles
  #    parsing ("mcp add: unknown flag network" - the orphaned --args values
  #    ended up as stray tokens seen at the wrong loop position).
  #  - sed backrefs: names are plain identifiers, a literal-prefix match is
  #    enough. The loop feeds whole lines to the final sed in one invocation.
  _mcp_rm_tmp=/tmp/mcp_remove.$$
  : > "$_mcp_rm_tmp"
  _mcp_in_block=0
  while IFS= read -r _mcp_line; do
    if [ "$_mcp_in_block" = "0" ]; then
      case "$_mcp_line" in
        "mcp add $1 "*|"mcp add $1") _mcp_in_block=1 ;;
        *) printf '%s\n' "$_mcp_line" >> "$_mcp_rm_tmp" ;;
      esac
    else
      # inside the block: continuation lines end with '\'; the block ends at
      # the first line NOT ending in backslash
      case "$_mcp_line" in
        *'\') : ;;
        *) _mcp_in_block=0 ;;
      esac
    fi
  done < "$crushrc"
  cat "$_mcp_rm_tmp" > "$crushrc" 2>/dev/null && rm -f "$_mcp_rm_tmp" || true
}

# mem0 MCP url: optional shared-memory layer (empty = no mem0 in crush)
# - unset url           : scrub any mem0 line (operator turned memory OFF)
# - url but no token    : skip mem0 (would 401 forever) + warn
# - url and token       : rewrite/append the mcp add mem0 line with both
MEM0_URL=$(jq -r '.mem0_mcp_url // ""' /data/options.json)
if [ -z "$MEM0_URL" ]; then
  mcp_remove mem0
elif [ -z "$MEM0_MCP_TOKEN" ]; then
  echo "[addon][WARN] mem0_mcp_url set but no token found - mem0 MCP skipped"
  mcp_remove mem0
else
  mcp_remove mem0
  # the token is passed as an env reference, NOT inlined - it may contain
  # characters sed would eat, and it must not land in stored files
  printf 'mcp add mem0 --type http --url "%s" --header Authorization "Bearer $MEM0_MCP_TOKEN"\n' "$MEM0_URL" >> "$crushrc"
  MCP_TOKENS_EXPORTED=1
fi

# ── mcp_servers option: configure ANY MCP server from the Options tab ────
# JSON array, each entry one server. Two shapes (like the mem0 handling above):
#   http:   {"name":"vision","url":"http://host:3011/mcp","token_url":"http://host/vision-mcp.token"}
#           token_url fetches the bearer at startup; direct "token":"..." also
#           works. Omitting both adds the server without an auth header.
#   stdio:  {"name":"openscad","command":"docker","args":["run","--rm","-i","--network","host",
#            "alpine/socat","STDIO","TCP:host:3010"],"timeout":20}
# Merge is additive by name: entries replace only their own server's line
# (mcp_remove above), never other servers a central template registers.
# Empty/unset or INVALID JSON = no changes; template lines stay authoritative.
MCP_JSON="${MCP_SERVERS:-$(jq -r '.mcp_servers // "[]"' /data/options.json 2>/dev/null)}"
if [ "$MCP_JSON" != "[]" ] && echo "$MCP_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  MCP_COUNT=$(echo "$MCP_JSON" | jq 'length')
  _mcp_idx=0
  while [ "$_mcp_idx" -lt "$MCP_COUNT" ]; do
    MCP_ENTRY=$(echo "$MCP_JSON" | jq -c ".[$_mcp_idx]")
    _mcp_idx=$((_mcp_idx + 1))
    MCP_NAME=$(echo "$MCP_ENTRY" | jq -r '.name // ""')
    MCP_URL=$(echo "$MCP_ENTRY" | jq -r '.url // ""')
    MCP_CMD=$(echo "$MCP_ENTRY" | jq -r '.command // ""')
    if [ -z "$MCP_NAME" ]; then
      echo "[addon][WARN] mcp_servers entry #$_mcp_idx has no name - skipped"
      continue
    fi
    case "$MCP_NAME" in
      *[!A-Za-z0-9_-]*) echo "[addon][WARN] mcp_servers: '$MCP_NAME' not a safe name - skipped"; continue ;;
    esac
    mcp_remove "$MCP_NAME"
    if [ -n "$MCP_URL" ]; then
      MCP_TOK=$(echo "$MCP_ENTRY" | jq -r '.token // ""')
      MCP_TOK_URL=$(echo "$MCP_ENTRY" | jq -r '.token_url // ""')
      if [ -z "$MCP_TOK" ] && [ -n "$MCP_TOK_URL" ]; then
        MCP_TOK=$(curl -fsSL --max-time 10 "$MCP_TOK_URL" 2>/dev/null | tr -d '[:space:]')
      fi
      if [ -n "$MCP_TOK" ]; then
        MCP_TOKENS_EXPORTED=1
        export "MCP_TOKEN_${MCP_NAME}=${MCP_TOK}"
        printf 'mcp add %s --type http --url "%s" --header Authorization "Bearer $MCP_TOKEN_%s"\n' "$MCP_NAME" "$MCP_URL" "$MCP_NAME" >> "$crushrc"
      else
        # no token resolves: still wire the server (LAN servers may not need
        # auth) - same posture as mem0's token fetch failure
        printf 'mcp add %s --type http --url "%s"\n' "$MCP_NAME" "$MCP_URL" >> "$crushrc"
        [ -n "$MCP_TOK_URL" ] && echo "[addon][WARN] mcp_servers '$MCP_NAME': token_url yielded nothing - added without auth header"
      fi
    elif [ -n "$MCP_CMD" ]; then
      MCP_ARGS_LINE=""
      MCP_NARGS=$(echo "$MCP_ENTRY" | jq '.args // [] | length')
      _arg_idx=0
      while [ "$_arg_idx" -lt "$MCP_NARGS" ]; do
        # one --args token per element: crush exec's argv directly, no shell
        # splitting - values may contain spaces/slashes safely. SPACE form is
        # required: crush's shell-config flag engine (internal/shellconfig/
        # flags.go, stable v0.88->main) only matches the exact token --args;
        # the =-form dies with "mcp add: unknown flag --args=...". Dash-prefixed
        # values (--network, --rm) are consumed verbatim by nextArg, no quoting
        # needed.
        MCP_ARGS_LINE="$MCP_ARGS_LINE --args $(echo "$MCP_ENTRY" | jq -r ".args[$_arg_idx]")"
        _arg_idx=$((_arg_idx + 1))
      done
      MCP_TIMEOUT=$(echo "$MCP_ENTRY" | jq -r '.timeout // ""')
      if [ -n "$MCP_TIMEOUT" ]; then
        printf 'mcp add %s --type stdio --command "%s"%s --timeout %s\n' "$MCP_NAME" "$MCP_CMD" "$MCP_ARGS_LINE" "$MCP_TIMEOUT" >> "$crushrc"
      else
        printf 'mcp add %s --type stdio --command "%s"%s\n' "$MCP_NAME" "$MCP_CMD" "$MCP_ARGS_LINE" >> "$crushrc"
      fi
    else
      echo "[addon][WARN] mcp_servers '$MCP_NAME': neither url nor command set - skipped"
    fi
  done
  echo "[addon] mcp_servers: $MCP_COUNT server(s) applied from options"
elif [ "$MCP_JSON" != "[]" ]; then
  echo "[addon][WARN] mcp_servers is not a valid JSON array - ignored (template mcp lines unchanged)"
fi
# Tokens referenced by generated mcp lines ride the environment into crush's
# runtime (with S6_KEEP_ENV=1 they survive s6 exec); the crushrc only carries
# $VAR references, so secret values never land in stored files.

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