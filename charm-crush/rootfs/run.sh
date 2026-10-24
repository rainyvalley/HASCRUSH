#!/bin/bash
# Crush add-on startup: config fetch + key resolution + persistence + ttyd.
set -e

# Owner-only defaults for EVERYTHING this script creates: the persisted
# directory ends up carrying API keys / fetched tokens / the bash crushrc, and
# nothing in it is ever read by a non-root process in the container.
umask 077

# Tell s6-overlay to keep the container environment (it strips it by default).
# The authoritative copy is the Dockerfile ENV (stage0 reads it before any user
# code runs); this re-export is belt-and-braces for non-image executions.
export S6_KEEP_ENV=1

# ── lib.sh: pure helpers (validators, mcp crushrc surgery, model slots) ──
# Extracted to their own file so the bats unit suite (tests/) can source and
# test them without booting the add-on; the Dockerfile copies lib.sh next to
# run.sh in the image (/usr/local/bin), so sourcing it relative to this
# script works both there and from the repo. Sourced at the TOP so every
# definition precedes its first use (they were defined later in the file
# before the extraction - strictly earlier is behaviorally identical).
# Missing lib.sh is fatal: the mcp/model/validator logic would be undefined.
__libdir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE:-$0}")" && pwd -P)
# shellcheck source=charm-crush/rootfs/lib.sh
. "$__libdir/lib.sh"
unset __libdir

# ── Supervisor token resolution ───────────────────────────────────────────
# SUPERVISOR_TOKEN is injected into the container env by the Supervisor itself.
# s6-overlay (pid 1) strips the container env before run.sh starts when
# S6_KEEP_ENV is unset at stage0 time; with the Dockerfile setting S6_KEEP_ENV=1
# the env survives intact, and this chain additionally recovers the token from
# the s6 env dumps for images/runs where it did not: /run/s6/container_environment
# (stage0's dump when KEEP_ENV is off), /run/s6/basedir/env (KEEP_ENV on) and
# /var/run/s6 layouts (v2). The result is re-exported as SUPERVISOR_TOKEN (the
# `ha` CLI reads that literal variable) and HA_TOKEN for the REST calls in this
# script and in crush sessions.
resolve_supervisor_token() {
  [ -n "$SUPERVISOR_TOKEN" ] || SUPERVISOR_TOKEN="${HASSIO_TOKEN:-}"
  if [ -z "$SUPERVISOR_TOKEN" ]; then
    for _name in SUPERVISOR_TOKEN HASSIO_TOKEN; do
      for _base in /run/s6/container_environment /run/s6/basedir/env /var/run/s6/container_environment; do
        if [ -r "$_base/$_name" ]; then
          _val=$(head -c 4096 "$_base/$_name" 2>/dev/null | tr -d '[:space:]')
          if [ -n "$_val" ]; then
            SUPERVISOR_TOKEN="$_val"
            echo "[addon] SUPERVISOR_TOKEN recovered from s6 container_environment ($_base/$_name)"
            break 2
          fi
        fi
      done
    done
  fi
  unset _name _base _val
}
resolve_supervisor_token
export SUPERVISOR_TOKEN
[ -n "$HASSIO_TOKEN" ] || HASSIO_TOKEN="$SUPERVISOR_TOKEN"
export HASSIO_TOKEN
HA_TOKEN="$SUPERVISOR_TOKEN"; export HA_TOKEN
export HA_URL="http://supervisor/core"

# s6-overlay-suexec strips the container environment when it re-execs the
# service stack; tmux/bash/crush then see an empty $HOME and abort with
# "Failed to get user home directory". Re-pin the basics here (and let s6
# keep the whole env below).
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export SHELL="${SHELL:-/bin/bash}"

# ── Supervisor API self-check: make denials visible at startup ──────────
# The token is resolved above (env / legacy alias / s6 envdir) and granted
# reach by the hassio_api / homeassistant_api flags in config.yaml; never by
# a user-set option.
# One test call each so a denial shows up in the add-on log with a cause,
# instead of as bare 401s later - there is no option field for this key,
# only these flags (update/reinstall the add-on if they ever 401/403).
if [ -z "$HA_TOKEN" ]; then
  echo "[addon][WARN] SUPERVISOR_TOKEN missing after env + legacy HASSIO_TOKEN + s6 envdir recovery - HA/supervisor API calls will 401 (update or reinstall the add-on so the Supervisor issues its key)"
else
  # The two probes are independent: run them concurrently (worst case 5 s
  # instead of 10 s when the Supervisor is slow/unreachable); the log lines
  # still print in the same order.
  _core_out=/tmp/.core_code.$$
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $HA_TOKEN" http://supervisor/core/api/ > "$_core_out" 2>/dev/null &
  _core_pid=$!
  SUP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $HA_TOKEN" http://supervisor/info || true)
  case "$SUP_CODE" in
    200) echo "[addon] Supervisor API: OK (token accepted)" ;;
    401) echo "[addon][WARN] Supervisor API: token DENIED 401 (invalid/re-keyed) - update or reinstall the add-on" ;;
    403) echo "[addon][WARN] Supervisor API: access DENIED 403 (role/permission) - hassio_api/hassio_role not granted; update the add-on" ;;
    *)   echo "[addon][WARN] Supervisor API: unreachable (HTTP ${SUP_CODE:-none}) - Supervisor restarting or DNS issue" ;;
  esac
  wait "$_core_pid" 2>/dev/null || true
  CORE_CODE=$(cat "$_core_out" 2>/dev/null || true)
  rm -f "$_core_out"
  case "$CORE_CODE" in
    200) echo "[addon] HA Core API: OK (homeassistant_api granted)" ;;
    401) echo "[addon][WARN] HA Core API: token DENIED 401 - homeassistant_api not active; update the add-on" ;;
    *)   echo "[addon][WARN] HA Core API: not reachable (HTTP ${CORE_CODE:-none}) - normal while HA Core is still starting" ;;
  esac
fi

# Data lives in the add-on's PRIVATE config folder (addon_config, mounted at
# /config). It used to live in /homeassistant/.crushdata, which every add-on
# with write access to the HA config folder can change; persist_migrate
# (lib.sh) copies that old folder over once and leaves it in place.
PERSIST_DIR=/config/crushdata
OLD_PERSIST_DIR=/homeassistant/.crushdata
persist_migrate "$OLD_PERSIST_DIR" "$PERSIST_DIR" "$PERSIST_DIR/.migrated-from-homeassistant" || true
mkdir -p "$PERSIST_DIR/config/crush" "$PERSIST_DIR/data" /root/.config /root/.local/share
chmod 700 "$PERSIST_DIR" 2>/dev/null || true

# ── Optional env-file defaults ─────────────────────────────────────────
# /config/crushdata/env (KEY=VALUE lines) sets DEFAULTS via environment
# variables — the script's own `VAR=${VAR:-...}` chains honor it everywhere.
# Precedence: real environment (docker run -e / HA env) > this file > add-on
# option > central URL > persisted file. Example lines:
#   OLLAMA_API_KEY=sk-...
# Allowed names: OLLAMA_API_KEY OLLAMA_KEY_URL LOCAL_OLLAMA_URL DISTI_TOKEN
# MCP_SERVERS MCP_TOKEN_* THIRD_PARTY_* CRUSH_* (env_name_ok in lib.sh).
#   MCP_TOKEN_<name>=...  (NOT a token source - mcp_servers entries carry
#                        their own token/token_url; run.sh exports one of
#                        these per entry after resolving it. A manually set
#                        value is only read by a fetched template that
#                        references $MCP_TOKEN_<name> itself)
#   CRUSH_CONFIG_URL=http://my-server/crushrc.template
# Missing file = no defaults set; everything still works from options/schema.
ENV_FILE="$PERSIST_DIR/env"
if [ -r "$ENV_FILE" ]; then
  # Only KEY=VALUE and export KEY=VALUE lines whose NAME is on the allow-list
  # (env_name_ok, lib.sh) are honored - anything else (shell code, pipes,
  # command substitution, LD_PRELOAD, BASH_ENV, PATH ...) is FILTERED OUT and
  # never runs: a filtered copy is sourced, not the raw file, so a stray or
  # malicious line in this file can never execute as code at startup (this
  # runs as root inside the add-on).
  ENV_CLEAN="$PERSIST_DIR/.env.clean.$$"
  # The value grammar (ENV_PAT) and the filter (env_file_clean) live in
  # rootfs/lib.sh with their rationale, so the bats suite (tests/) can pin
  # them. Values are never printed: a rejected line may carry a real secret.
  BAD=$(env_file_clean "$ENV_FILE" "$ENV_CLEAN")
  if [ -n "$BAD" ]; then
    echo "[addon][WARN] $ENV_FILE has lines that were SKIPPED (not KEY=VALUE, or a name this add-on does not read) - nothing was executed:" >&2
    echo "$BAD" | sed 's/^/    /' >&2
  fi
  if [ -s "$ENV_CLEAN" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_CLEAN"
    set +a
    echo "[addon] env defaults sourced from $ENV_FILE (KEY=VALUE lines only)"
  fi
  rm -f "$ENV_CLEAN"
fi

# ── LAN Ollama URL (local_ollama_url option / LOCAL_OLLAMA_URL env) ───────
# The crushrc is bash run by crush and reads $LOCAL_OLLAMA_URL from the
# environment, so resolve it here (env > env file > option), validate it, and
# export it. Invalid = ignored (no ollama-local provider is added).
LOCAL_OLLAMA_URL="${LOCAL_OLLAMA_URL:-$(jq -r '.local_ollama_url // ""' /data/options.json)}"
val_check "$LOCAL_OLLAMA_URL" safe_url "local_ollama_url failed charset validation (must be http/https + URL-safe chars) - ignored" || LOCAL_OLLAMA_URL=""
export LOCAL_OLLAMA_URL

# ── Persistence symlinks ────────────────────────────────────────────────
# Everything crush writes lives in /config/crushdata/ so it survives
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
- admin-only Supervisor endpoints (`/os/ssh/authorized_keys`, `/addons/<slug>/security`, ...) -> 403: this add-on runs the MANAGER Supervisor role, not admin
- docker CLI -> no docker socket; the USER may toggle Protection mode if ever needed
- Profile-page long-lived tokens do NOT work on `http://supervisor`

Safe alternatives: `ha` CLI for Core-only commands (pre-authed: `ha core logs`,
`ha core stats`), REST with `$HA_TOKEN` (`${HA_URL}/api/states/...`,
`${HA_URL}/api/services/...`), and plain files under the mapped paths.
<!-- hasscrush-limits-end -->'
if [ ! -f "$CRUSH_MD" ]; then
cat > "$CRUSH_MD" <<EOF
# Crush - Home Assistant Add-on

$LIMITS_BODY

## Path Mapping

In this add-on container, paths map differently than HA Core:
- \`/homeassistant\` = HA config directory (what HA Core calls \`/config\`)
- \`/config\` here is this add-on's own private folder, NOT the HA config directory - use \`/homeassistant\` for HA files

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

# ── charset validators (safe_url / safe_text / val_check) ────────────────
# The validators live in rootfs/lib.sh; warn_plain_http is boot-log policy.
# plain-http note (user decision: http stays allowed); $1 = exact warn body,
# $2 = the URL. http carries secrets/writable scripts unencrypted on the wire.
warn_plain_http() { case "$2" in http://*) echo "[addon][WARN] $1; prefer https" >&2 ;; esac; }

# ── crushrc: central template, or a self-contained fallback ────────────
crushrc="$PERSIST_DIR/config/crush/crushrc"
CONFIG_URL="${CRUSH_CONFIG_URL:-$(jq -r '.crush_config_url // ""' /data/options.json)}"
val_check "$CONFIG_URL" safe_url "crush_config_url failed charset validation (must be http/https + URL-safe chars) - ignored" || CONFIG_URL=""
# Plain-HTTP caveat (user decision: http stays allowed): the fetched template
# is a BASH script crush later executes, so tampered-in-transit content runs
# in this add-on as root.
# The fetched file is a BASH script that runs as root in this add-on, so it is
# only used when (1) crush_config_sha256 pins its exact content, and (2) the
# URL is https:// unless crush_config_allow_http is on. Anything else keeps the
# config already on disk (the last good copy) and logs why.
CONFIG_SHA=$(printf '%s' "${CRUSH_CONFIG_SHA256:-$(jq -r '.crush_config_sha256 // ""' /data/options.json)}" | tr -d '[:space:]')
CONFIG_ALLOW_HTTP="${CRUSH_CONFIG_ALLOW_HTTP:-$(jq -r '.crush_config_allow_http // false' /data/options.json)}"
case "$CONFIG_ALLOW_HTTP" in true|1|yes) CONFIG_ALLOW_HTTP=true ;; *) CONFIG_ALLOW_HTTP=false ;; esac
curl_guard "$CONFIG_URL"
# Sanity-check the FULL download, not just the first 2 KB: every line is
# executable as bash, so validation must cover the whole file. Size-capped
# at 1 MB (--max-filesize plus an explicit wc -c for chunked/no-length
# servers) so a runaway/infinitely-fed URL cannot fill the tmpfs.
CRUSHRC_FETCHED=0
CONFIG_FETCH=0
if [ -n "$CONFIG_URL" ]; then
  if [[ "$CONFIG_URL" == http://* ]] && [ "$CONFIG_ALLOW_HTTP" != true ]; then
    echo "[addon][WARN] crush_config_url is plain http:// and crush_config_allow_http is off - central config NOT fetched (use https://, or turn the option on to accept plain http)" >&2
  elif ! is_sha256 "$CONFIG_SHA"; then
    echo "[addon][WARN] crush_config_url is set but crush_config_sha256 is missing or not 64 hex characters - central config NOT fetched. Set it to the sha256 of the file (sha256sum crushrc.template)" >&2
  else
    CONFIG_FETCH=1
    warn_plain_http "crush_config_url uses plain http (allowed by crush_config_allow_http) - the pinned hash still protects the script" "$CONFIG_URL"
  fi
fi
if [ "$CONFIG_FETCH" = 1 ]; then
  if curl -fsSL "${CURL_GUARD[@]}" --retry 2 --retry-delay 2 --max-time 10 --max-filesize 1048576 "$CONFIG_URL" -o /tmp/crushrc.new 2>/dev/null \
     && [ "$(wc -c < /tmp/crushrc.new)" -le 1048576 ]; then
    if ! sha256_matches /tmp/crushrc.new "$CONFIG_SHA"; then
      echo "[addon][WARN] central crushrc HASH MISMATCH: pinned ${CONFIG_SHA,,}, downloaded $(file_sha256 /tmp/crushrc.new) - fetched file REFUSED, keeping the last good config" >&2
    elif grep -qE '(provider|model) (add|large|small)|crushrc' /tmp/crushrc.new \
         && bash -n /tmp/crushrc.new 2>/dev/null \
         && cp /tmp/crushrc.new "$crushrc.new"; then
      # /tmp -> persist dir is a cross-filesystem move (copy + unlink, NOT
      # atomic); stage a copy in the destination dir so the final rename(2) is.
      mv -f "$crushrc.new" "$crushrc"
      CRUSHRC_FETCHED=1
      echo "[addon] crushrc fetched from the central template ($(redact_url "$CONFIG_URL")), sha256 matches the pin"
    else
      echo "[addon][WARN] central crushrc matched the pinned hash but failed the content or bash-syntax check - NOT applied" >&2
    fi
  else
    echo "[addon][WARN] central crushrc download failed (HTTP/size) - NOT applied, keeping the last good config" >&2
  fi
fi
rm -f /tmp/crushrc.new "$crushrc.new"
if [ "$CRUSHRC_FETCHED" != 1 ]; then
  if [ ! -f "$crushrc" ]; then
    cat > "$crushrc" <<'RCEOF'
# Built-in fallback crushrc (add-on). Set crush_config_url to manage centrally.

# Key resolution: environment -> addon option -> persisted file.
# NOTE the classic bug fixed here: `: "${VAR:-cmd}"` does NOT assign!
[ -n "$OLLAMA_API_KEY" ] || OLLAMA_API_KEY="$(jq -r '.ollama_api_key // ""' /data/options.json 2>/dev/null)"
[ -n "$OLLAMA_API_KEY" ] || OLLAMA_API_KEY="$(grep -m1 -s '^OLLAMA_API_KEY=' "$HOME/.config/crush/ollama.env" 2>/dev/null | cut -s -d= -f2-)"
export OLLAMA_API_KEY
[ -n "$OLLAMA_API_KEY" ] || { echo "ERROR: FAILED - no Ollama API key. Set the add-on option
or put OLLAMA_API_KEY=... in ~/.config/crush/ollama.env (home is not
defined without it)."; exit 1; }

# --discover-models true merges the providers' full catalogs into the picker
# (every ollama.com model the key can call + the whole LAN catalog) - explicit
# `model add` entries below always win over discovered ones. Toggle:
# crush_discover_models option / CRUSH_DISCOVER_MODELS env.
provider add ollama-cloud --type openai-compat --base-url "https://ollama.com/v1" --api-key "$OLLAMA_API_KEY" --discover-models true
if [ -n "$LOCAL_OLLAMA_URL" ]; then
provider add ollama-local --type ollama --base-url "$LOCAL_OLLAMA_URL" --discover-models true
fi

# Default = DeepSeek V4.1 Flash with thinking (effort high = model-decided depth).
# The same model fills the daily and helper slots. crush_reasoning_effort
# changes the daily slot only. The "deep" model is registered for the picker
# but is not a slot.
model add ollama-cloud/deepseek-v4.1-flash --name "DeepSeek V4.1 Flash" --context-window 1048576 --default-max-tokens 131072 --can-reason true --supports-images true --reasoning-effort high --price-input 0.3 --price-output 1.2
model large ollama-cloud/deepseek-v4.1-flash --reasoning-effort high
model small ollama-cloud/deepseek-v4.1-flash --reasoning-effort high

# Former defaults, still registered as picker alternatives (pick them via / in the TUI):
model add ollama-cloud/glm-5.3-flash --name "GLM 5.3 Flash" --context-window 1048576 --default-max-tokens 131072 --can-reason true --reasoning-effort high --price-input 0.15 --price-output 0.5
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
    echo "[addon] keeping the existing crushrc (no central config applied)"
  fi
fi
# umask 077 covers freshly written files; older installs may still have a
# world-readable persisted rc (readable by non-root in the container only,
# but keep it owner-only: the rc resolves/exports the API key).
chmod 600 "$crushrc" 2>/dev/null || true

# ── config-version check (fires on EVERY start/restart) ────────────────
# The central crushrc template carries a `# config-version: N` stamp and the
# same distribution point publishes the matching /config.version; a
# functional change bumps BOTH in lockstep (see /srv/crush). Comparing them
# on every start makes staleness — or a disti-side out-of-sync mistake —
# visible in the add-on log instead of silently grinding on a stale config.
# config.version is a public bare integer (no token); the template URL
# doubles as the base for it (strip the file component).
CV_INSTALLED=$(sed -n 's/^# config-version:[[:space:]]*\([0-9]*\).*/\1/p' "$crushrc" 2>/dev/null | head -n 1 || true)
CV_CENTRAL=""
if [ "$CONFIG_FETCH" = 1 ]; then
  CV_CENTRAL=$(curl -fsSL "${CURL_GUARD[@]}" --max-time 5 "${CONFIG_URL%/*}/config.version" 2>/dev/null | tr -d '[:space:]' | head -c 16 || true)
  case "$CV_CENTRAL" in *[!0-9]*) CV_CENTRAL="" ;; esac
fi
if [ "$CONFIG_FETCH" != 1 ]; then
  echo "[addon] central config not in use - no config-version to check"
elif [ -n "$CV_CENTRAL" ] && [ "$CV_CENTRAL" = "$CV_INSTALLED" ]; then
  echo "[addon] crush config-version ${CV_CENTRAL} - current"
elif [ -n "$CV_CENTRAL" ] && [ "$CRUSHRC_FETCHED" = "1" ]; then
  echo "[addon][WARN] config-version mismatch: central=${CV_CENTRAL} template=${CV_INSTALLED:-none} - /config.version and the crushrc template are OUT OF SYNC (bump both together)"
elif [ -n "$CV_CENTRAL" ]; then
  echo "[addon][WARN] crushrc kept from a previous start (fetch failed) and it is STALE: central config-version=${CV_CENTRAL}, installed=${CV_INSTALLED:-none} - will retry next start"
else
  echo "[addon][WARN] central config-version unreachable - installed stamp: ${CV_INSTALLED:-none}"
fi

# ── LLM provider: ollama (default) or a 3rd-party OpenAI-compatible API ─
PROVIDER=$(jq -r '.provider // "ollama"' /data/options.json)
TPID=openai-compat-3p
TP_ACTIVE=0
# undo a previous start's remap first (provider_reset in rootfs/lib.sh): the
# persisted rc must never keep pointing at a third-party host this start did
# not configure
provider_reset "$TPID"
if [ "$PROVIDER" = "third_party" ]; then
  TP_URL="${THIRD_PARTY_BASE_URL:-$(jq -r '.third_party_base_url // ""' /data/options.json)}"
  TP_KEY="${THIRD_PARTY_API_KEY:-$(jq -r '.third_party_api_key // ""' /data/options.json)}"
  if [ -z "$TP_URL" ] || [ -z "$TP_KEY" ]; then
    echo "[addon][ERROR] provider=third_party but third_party_base_url / third_party_api_key are missing - falling back to ollama"
  elif ! safe_url "$TP_URL"; then
    echo "[addon][WARN] third_party_base_url failed charset validation (http/https + URL-safe chars only) - falling back to ollama" >&2
  else
    provider_remap "$TPID" "$TP_URL"
    TP_ACTIVE=1
    warn_plain_http "third_party_base_url uses plain http - the API key travels unencrypted" "$TP_URL"
    # pre-fix boots ran `sed -iE`, which is -i with backup SUFFIX "E": drop
    # the stray copy of the rc that left next to it
    rm -f "${crushrc}E"
    # the key stays as --api-key "$OLLAMA_API_KEY" in the rc; the third-party
    # key is exported as OLLAMA_API_KEY AFTER the Ollama key block below (no
    # sed on key values: they can contain any character). Exporting it here
    # would make that block persist the third-party key as the Ollama key.
    echo "[addon] provider=third_party: models remapped to $TPID ($(redact_url "$TP_URL"))"
  fi
fi

# ── Model auto-discovery: crush_discover_models option / CRUSH_DISCOVER_MODELS env
# The native --discover-models true provider flag (also used by the central
# template) merges the provider's full catalog into the TUI picker; explicit
# `model add` entries win on conflicts. false disables it everywhere (fetched
# templates included); true only ever touches the add-on's own fallback rc -
# a fetched template stays exactly what its author served.
DISCOVER_MODELS="${CRUSH_DISCOVER_MODELS:-$(jq -r 'if .crush_discover_models == null then true else .crush_discover_models end' /data/options.json)}"
case "$DISCOVER_MODELS" in false|0|no) DISCOVER_MODELS=false ;; *) DISCOVER_MODELS=true ;; esac
if [ "$DISCOVER_MODELS" = false ]; then
  discover_models_apply false
  echo "[addon] model auto-discovery disabled (crush_discover_models=false) - picker shows only hand-registered models"
elif [ "$CRUSHRC_FETCHED" != "1" ] \
   && grep -q '^# Built-in fallback crushrc' "$crushrc" 2>/dev/null \
   && grep -q -- '--discover-models false' "$crushrc" 2>/dev/null; then
  # an earlier start with discovery off left `false` in the persisted rc: flip it back
  discover_models_apply true
  echo "[addon] model auto-discovery enabled on the existing fallback crushrc"
elif [ "$CRUSHRC_FETCHED" != "1" ] \
   && grep -q '^# Built-in fallback crushrc' "$crushrc" 2>/dev/null \
   && ! grep -q -- '--discover-models' "$crushrc" 2>/dev/null; then
  # legacy fallback rc written before discovery existed: add the flag in place
  discover_models_apply true
  echo "[addon] model auto-discovery enabled on the existing fallback crushrc"
fi

# ── Ollama API key: option -> central key URL -> existing file ─────────
keyfile="$PERSIST_DIR/config/crush/ollama.env"
OPT_KEY="${OLLAMA_API_KEY:-$(jq -r '.ollama_api_key // ""' /data/options.json)}"
KEY_URL="${OLLAMA_KEY_URL:-$(jq -r '.ollama_key_url // ""' /data/options.json)}"
val_check "$KEY_URL" safe_url "ollama_key_url failed charset validation (http/https + URL-safe chars only) - ignored" || KEY_URL=""
# plain http ships the API key unencrypted on the wire; allowed (user
# decision, LAN installer convention) but always logged
warn_plain_http "ollama_key_url uses plain http - the API key travels unencrypted" "$KEY_URL"
# ── Disti download credential (optional) ───────────────────────────────
# When set, secret-file fetches (ollama_key_url and mcp_servers token_url)
# send it as an X-Disti-Token header - the crush disti (nginx in /srv/crush)
# serves its token/key files behind that header check. It is a DOWNLOAD
# credential only: never an MCP bearer token, never written to any stored
# file. Header, not a ?token= query: request lines get logged, headers don't.
DISTI_TOKEN="${DISTI_TOKEN:-$(jq -r '.disti_token // ""' /data/options.json)}"  # env wins via ${VAR:-}
case "$DISTI_TOKEN" in
  "") ;;
  *[!A-Za-z0-9._~-]*) echo "[addon][WARN] disti_token failed charset validation (URL-safe chars only) - gated fetches run without it" >&2; DISTI_TOKEN="" ;;
esac
DISTI_CURL=()
# Redirects are followed only when no credential header is sent: curl would
# repeat X-Disti-Token on the redirected host. With a token set, a redirect
# simply fails the fetch (the body then never passes the content checks).
DISTI_LOC=(-L)
if [ -n "$DISTI_TOKEN" ]; then
  DISTI_CURL=(-H "X-Disti-Token:${DISTI_TOKEN}")
  DISTI_LOC=()
fi
touch "$keyfile"; chmod 600 "$keyfile"
if [ -n "$OPT_KEY" ]; then
  # addon option wins; rewrite the key file DELIBERATELY (not sed: keys may
  # contain '/', '#' or other sed-specials which would corrupt s/// expressions)
  { grep -v '^OLLAMA_API_KEY=' "$keyfile" || true; printf 'OLLAMA_API_KEY=%s\n' "$OPT_KEY"; } > "$keyfile.tmp"
  mv "$keyfile.tmp" "$keyfile"
  chmod 600 "$keyfile"
  echo "[addon][INFO] ollama API key set (env/env-file/option)"
elif [ -n "$KEY_URL" ] && curl_guard "$KEY_URL" && curl -fsS "${DISTI_LOC[@]}" "${CURL_GUARD[@]}" --max-time 10 --max-filesize 65536 "${DISTI_CURL[@]}" "$KEY_URL" -o /tmp/key.new 2>/dev/null \
     && grep -q '^OLLAMA_API_KEY=' /tmp/key.new; then
  # pin the fetched file owner-only the moment it exists: between the curl
  # above and the rm below, /tmp/key.new carries the key in the clear
  chmod 600 /tmp/key.new 2>/dev/null || true
  CENTRAL=$(grep -m1 '^OLLAMA_API_KEY=' /tmp/key.new)
  LOCAL=$(grep -m1 -s '^OLLAMA_API_KEY=' "$keyfile" || true)
  if [ "$CENTRAL" != "$LOCAL" ]; then
    { grep -v '^OLLAMA_API_KEY=' "$keyfile" 2>/dev/null || true; echo "$CENTRAL"; } > "$keyfile.tmp"
    # chmod BEFORE the mv: mv replaces the persisted file, and there must be
    # no window where the refreshed key sits world-readable at the destination
    chmod 600 "$keyfile.tmp" 2>/dev/null || true
    mv "$keyfile.tmp" "$keyfile"
    chmod 600 "$keyfile"   # mv REPLACES the file - re-pin owner-only (pre-1.0.27 installs could end up 644 here)
    echo "[addon][INFO] ollama API key refreshed from $(redact_url "$KEY_URL")"
  fi
  rm -f /tmp/key.new   # the fetched key never lingers in /tmp
else
  rm -f /tmp/key.new   # cover fetch attempts that failed mid-download too
  [ -s "$keyfile" ] && echo "[addon][INFO] using existing persisted ollama key" \
    || echo "[addon][WARN] no ollama API key found (option, key URL, or persisted file)"
fi
# third-party provider: the rc's --api-key "$OLLAMA_API_KEY" now carries the
# third-party key (set only after the persisting block above ran)
if [ "$TP_ACTIVE" = 1 ]; then
  export OLLAMA_API_KEY="$TP_KEY"
fi
# ── MCP token plumbing (all servers, incl. mem0, via mcp_servers JSON) ──
# Every token is carried by its OWN mcp_servers entry ("token": or
# "token_url":); resolved values are exported as MCP_TOKEN_<name> env vars
# and the crushrc references them, so secrets never land in stored files.

# Resolve one mcp_servers entry's token: $1 = server name, $2 = inline "token"
# value, $3 = "token_url" to fetch. Result in MCP_TOK ("" = none resolved).
# The fetch is size-capped (--max-filesize plus a head -c trim on the value:
# a token is tens of bytes; this bounds both the download and what reaches
# the env/export). plain http carries the bearer in the clear AND the disti
# serves these files behind an X-Disti-Token header check; allowed (LAN
# convention) but always logged. Same for http and stdio entries.
mcp_token_fetch() {
  MCP_TOK="$2"
  if [ -z "$MCP_TOK" ] && [ -n "$3" ]; then
    if safe_url "$3"; then
      curl_guard "$3"
      MCP_TOK=$(curl -fsS "${DISTI_LOC[@]}" "${CURL_GUARD[@]}" --max-time 10 --max-filesize 65536 "${DISTI_CURL[@]}" "$3" 2>/dev/null | tr -d '[:space:]' | head -c 4096)
      warn_plain_http "mcp_servers '$1': token_url uses plain http - the token travels unencrypted" "$3"
    else
      echo "[addon][WARN] mcp_servers '$1': token_url failed charset validation - not fetched" >&2
      MCP_TOK=""
    fi
  fi
}

# ── mcp_servers option: ALL MCP servers, from the Options tab ────────────
# mem0 included (since 1.0.15): one JSON array, each entry one server:
#   http:   {"name":"vision","url":"http://host:3011/mcp","token_url":"http://host/vision-mcp.token"}
#           token_url fetches the bearer at startup; direct "token":"..." also
#           works; tokenless entries (browser/searxng) omit both. A "mem0"
#           entry carries its own token/token_url like every other server;
#           a mem0 entry with neither still gets wired but will 401 until a
#           token lands on the entry.
#           Omitting mem0 from the list = no memory MCP (the legacy
#           mem0_mcp_url field no longer wires anything; scrubbed below).
#   stdio:  {"name":"openscad","command":"socat","args":["STDIO","TCP:host:3010"],
#            "token_url":"https://host/openscad-mcp.token","timeout":20}
#           stdio entries take token/token_url too: when one resolves, the
#           line is emitted as a sh -c gate wrapper that sends the token as
#           the FIRST stdin line (the client half of a token-gated TCP
#           bridge; the relay tool must be in the image - socat is).
# Merge is additive by name: entries replace only their own server's line
# (mcp_remove, in lib.sh), never other servers a central template registers.
# Empty/unset or INVALID JSON = no changes; template lines stay authoritative
# - including a template's mem0 line for crush_config_url users.
MCP_JSON="${MCP_SERVERS:-$(jq -r '.mcp_servers // "[]"' /data/options.json 2>/dev/null)}"
MCP_JSON="${MCP_JSON:-[]}"   # the add-on's default mcp_servers option is "", not a JSON array
mcp_sanitize
# one validity check shared by the three uses below (loop, invalid-JSON warn,
# legacy mem0 scan): did jq parse the text as a JSON array?
MCP_JSON_VALID=0
if echo "$MCP_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  MCP_JSON_VALID=1
fi
if [ "$MCP_JSON_VALID" = 1 ] && [ "$MCP_JSON" != "[]" ]; then
  MCP_COUNT=0
  _mcp_idx=0
  mcp_token_claims_reset
  while IFS= read -r MCP_ENTRY; do
    MCP_COUNT=$((MCP_COUNT + 1))
    _mcp_idx=$((_mcp_idx + 1))
    # One jq spawn per entry for every field: mcp_parse_entry (lib.sh, unit-
    # tested) fills _mf - name url command token token_url timeout argsok
    # args... - with embedded NULs dropped. The strips below match the old
    # per-field `tr -d` sets exactly.
    mcp_parse_entry "$MCP_ENTRY"
    MCP_NAME=${_mf[0]//[$'\r\n ']/}
    MCP_URL=${_mf[1]//[$'\r\n']/}
    MCP_CMD=${_mf[2]//[$'\r\n']/}
    if [ -z "$MCP_NAME" ]; then
      echo "[addon][WARN] mcp_servers entry #$_mcp_idx has no name - skipped"
      continue
    fi
    case "$MCP_NAME" in
      *[!A-Za-z0-9_-]*) echo "[addon][WARN] mcp_servers: '$MCP_NAME' not a safe name - skipped"; continue ;;
    esac
    # generated rc fragments are bash; validate URL/command charsets before
    # anything is written (safe_url/safe_text: no shell metachars, so a
    # crafted option value can never become code in the crushrc)
    val_check "$MCP_URL" safe_url "mcp_servers '$MCP_NAME': url failed charset validation (http/https + URL-safe chars only) - skipped" || continue
    val_check "$MCP_CMD" safe_text "mcp_servers '$MCP_NAME': command failed charset validation (shell metachars not allowed) - skipped" || continue
    # the old server line is replaced only once the whole entry has passed
    # validation (mcp_remove just before each write below), so a bad entry
    # never deletes a working line a template registered
    if [ -z "$MCP_URL" ] && [ -z "$MCP_CMD" ]; then
      echo "[addon][WARN] mcp_servers '$MCP_NAME': neither url nor command set - skipped"
      continue
    fi
    # token/token_url resolve once here, identically for http and stdio
    MCP_TOK=${_mf[3]//[[:space:]]/}
    MCP_TOK_URL=${_mf[4]//[$'\r\n']/}
    mcp_token_fetch "$MCP_NAME" "$MCP_TOK" "$MCP_TOK_URL"
    MCP_TOKVAR=$(mcp_token_var "$MCP_NAME")   # '-' is legal in names, not in env vars (lib.sh)
    # a-b and a_b map to the same variable: skip the later token-bearing entry
    # rather than let its export overwrite the first server's token
    if [ -n "$MCP_TOK" ]; then mcp_token_claim "$MCP_NAME" || continue; fi
    if [ -n "$MCP_URL" ]; then
      if [ -n "$MCP_TOK" ]; then
        export "${MCP_TOKVAR}=${MCP_TOK}"
        mcp_remove "$MCP_NAME"
        printf 'mcp add %s --type http --url "%s" --header Authorization "Bearer $%s"\n' "$MCP_NAME" "$MCP_URL" "$MCP_TOKVAR" >> "$crushrc"
      else
        # no token resolves: still wire the server (LAN servers may not need
        # auth) - same posture as mem0's token fetch failure
        mcp_remove "$MCP_NAME"
        printf 'mcp add %s --type http --url "%s"\n' "$MCP_NAME" "$MCP_URL" >> "$crushrc"
        [ -n "$MCP_TOK_URL" ] && echo "[addon][WARN] mcp_servers '$MCP_NAME': token_url yielded nothing - added without auth header"
      fi
    else
      # stdio entries may ALSO carry token/token_url exactly like http
      # entries. When a token resolves, the entry is emitted as a sh -c
      # gate-pipe: the token goes out as the FIRST stdin line, then the
      # original command is exec'd against crush's stdin. That is the client
      # half of a token-gated TCP relay (e.g. an openscad bridge on :3010
      # that closes bare relays after ~1s) - the same shape the central
      # template ships via `docker run` for machines WITH a docker socket,
      # redone for the add-on's dockerless container, where the relay tool
      # (socat) must already be IN the image. The token is still only
      # REFERENCED in the rc ($MCP_TOKEN_<name>, exported just below) -
      # never inlined (since 1.0.25).
      MCP_ARGS_LINE=""
      # gate wrapper body (sh code run by `sh -c`): each command word gets a
      # double quote so a value with spaces stays one argv element. safe_text
      # rejects ALL quote/backslash/dollar characters, so nothing an operator
      # pastes can ever break out of those quotes or the rc's outer
      # single-quoted token below.
      MCP_GATE="exec \"${MCP_CMD}\""
      if [ "${_mf[6]}" != 1 ]; then
        echo "[addon][WARN] mcp_servers '$MCP_NAME': args must be a JSON array - entry skipped" >&2
        continue
      fi
      MCP_NARGS=$(( ${#_mf[@]} - 7 ))
      _arg_idx=0
      _mcp_args_ok=1
      while [ "$_arg_idx" -lt "$MCP_NARGS" ]; do
        # one double-quoted --args word per element (mcp_arg_fragment, lib.sh):
        # crush exec's argv directly, so a value with a space stays ONE
        # argument. SPACE form is
        # required: crush's shell-config flag engine (internal/shellconfig/
        # flags.go, stable v0.88->main) only matches the exact token --args;
        # the =-form dies with "mcp add: unknown flag --args=...". Dash-prefixed
        # values (--network, --rm) are consumed verbatim by nextArg, no quoting
        # needed.
        # a paste with an editor line-wrap can embed raw \n/\r inside a
        # value; strip them so the generated rc line never breaks mid-token
        _mcp_arg=${_mf[$((_arg_idx + 7))]//[$'\r\n']/}
        if ! _mcp_frag=$(mcp_arg_fragment "$_mcp_arg"); then
          echo "[addon][WARN] mcp_servers '$MCP_NAME': arg #$_arg_idx is empty or failed charset validation (shell metachars not allowed) - entry skipped" >&2
          _mcp_args_ok=0
          break
        fi
        MCP_ARGS_LINE="$MCP_ARGS_LINE$_mcp_frag"
        MCP_GATE="$MCP_GATE \"$_mcp_arg\""
        _arg_idx=$((_arg_idx + 1))
      done
      [ "$_mcp_args_ok" = "1" ] || continue
      MCP_TIMEOUT=${_mf[5]//[[:space:]]/}
      case "$MCP_TIMEOUT" in
        "") ;;
        # numeric only: the timeout is printf'd bare into the rc line
        *[!0-9]*) echo "[addon][WARN] mcp_servers '$MCP_NAME': timeout must be numeric - entry skipped" >&2; continue ;;
      esac
      if [ -n "$MCP_TOK" ]; then
        export "${MCP_TOKVAR}=${MCP_TOK}"
        # single-quoted rc token around the sh -c body keeps the variable
        # UNEXPANDED in the stored rc (resolved when crush launches the
        # server). The printf "%s\n" newline inside is written as literal
        # \n here and becomes a real newline inside the inner sh.
        MCP_RC="mcp add $MCP_NAME --type stdio --command sh --args -c --args '{ printf \"%s\\n\" \"\$${MCP_TOKVAR}\"; $MCP_GATE; }'"
      else
        MCP_RC="mcp add $MCP_NAME --type stdio --command \"$MCP_CMD\"$MCP_ARGS_LINE"
        # no token resolves: still wire the server (a bare relay is the
        # wrong posture for a gated bridge, so say so) - same posture as a
        # tokenless http entry
        [ -n "$MCP_TOK_URL" ] && echo "[addon][WARN] mcp_servers '$MCP_NAME': token_url yielded nothing - added WITHOUT the token gate (a gated bridge will close this relay)" >&2
      fi
      [ -n "$MCP_TIMEOUT" ] && MCP_RC="$MCP_RC --timeout $MCP_TIMEOUT"
      mcp_remove "$MCP_NAME"
      printf '%s\n' "$MCP_RC" >> "$crushrc"
    fi
  done < <(echo "$MCP_JSON" | jq -c '.[]')
  echo "[addon] mcp_servers: $MCP_COUNT server(s) applied from options"
  # belt-and-braces: the merge runs AFTER the pre-merge sanitize, so any
  # half-line it could emit (a newline surviving the strips above would
  # split tokens - "unknown flag 252:3010") lands in the rc unrepaired.
  # Re-sanitize the rc we just wrote.
  mcp_sanitize
elif [ "$MCP_JSON_VALID" != 1 ]; then
  echo "[addon][WARN] mcp_servers is not a valid JSON array - ignored (template mcp lines unchanged)"
fi
# mem0_mcp_url (pre-1.0.15 way to point at the memory MCP) no longer wires
# anything: an operator who had ONLY mem0_url set and empty mcp_servers must
# move to a mem0 entry in mcp_servers; clear any stale line so an old
# install can't keep a half-configured memory MCP - but only when the
# mcp_servers JSON did NOT just wire a fresh mem0 entry (that entry wins;
# scrubbing here would delete the new line, see 1.0.15 sim test).
LEGACY_MEM0_URL=$(jq -r '.mem0_mcp_url // ""' /data/options.json)
MCP_HAS_MEM0=0
if [ "$MCP_JSON_VALID" = 1 ]; then
  # jq -e alone exits 0 on an empty stream, so grep the output instead
  echo "$MCP_JSON" | jq -c '.[] | select(.name == "mem0")' 2>/dev/null | grep -q . && MCP_HAS_MEM0=1
fi
if [ -n "$LEGACY_MEM0_URL" ] && [ "$MCP_HAS_MEM0" != "1" ]; then
  echo "[addon][NOTICE] mem0_mcp_url option is retired - add a \"mem0\" entry to the mcp_servers JSON (url + token_url/token); removing any stale mem0 line"
  mcp_remove mem0
fi
# Tokens referenced by generated mcp lines ride the environment into crush's
# runtime (with S6_KEEP_ENV=1 they survive s6 exec); the crushrc only carries
# $VAR references, so secret values never land in stored files.

# ── Model defaults from options/env (apply to fetched or fallback rc) ──
# CRUSH_LARGE_MODEL / CRUSH_SMALL_MODEL / CRUSH_DEEP_MODEL / CRUSH_REASONING_EFFORT envs or the
# matching add-on options rewire the slots to whatever the operator picked; unknown/skipped values
# leave the config's own slots in place.
# One jq spawn for all seven slot fields (NUL-delimited so values - even
# ones with newlines/quotes - stay intact and land in the right slot; env-wins
# precedence preserved by the ${VAR:-} wrappers). Each slot is a picklist of
# known models plus a free-text *_custom override that wins when non-empty.
mapfile -d '' -t -- _mopts < <(jq -rj '[(.crush_large_model // ""), (.crush_small_model // ""), (.crush_deep_model // ""), (.crush_reasoning_effort // ""), (.crush_large_model_custom // ""), (.crush_small_model_custom // ""), (.crush_deep_model_custom // "")] | .[] | (tostring + "\u0000")' /data/options.json 2>/dev/null)
LARGE_MODEL="${CRUSH_LARGE_MODEL:-${_mopts[4]:-${_mopts[0]}}}"
SMALL_MODEL="${CRUSH_SMALL_MODEL:-${_mopts[5]:-${_mopts[1]}}}"
DEEP_MODEL="${CRUSH_DEEP_MODEL:-${_mopts[6]:-${_mopts[2]}}}"
EFFORT="${CRUSH_REASONING_EFFORT:-${_mopts[3]}}"
if [ "$TP_ACTIVE" = 1 ]; then
  # the option defaults name ollama-cloud/...; follow the remap (lib.sh)
  LARGE_MODEL=$(tp_model_id "$LARGE_MODEL" "$TPID")
  SMALL_MODEL=$(tp_model_id "$SMALL_MODEL" "$TPID")
  DEEP_MODEL=$(tp_model_id "$DEEP_MODEL" "$TPID")
fi
if [ "$TP_ACTIVE" = 1 ]; then
  # the picklist defaults name models that exist on Ollama Cloud, not on the
  # third-party service
  for _s in "$LARGE_MODEL" "$SMALL_MODEL"; do
    case "$_s" in
      "$TPID"/deepseek-v4.1-flash|"$TPID"/glm-5.3-flash|"$TPID"/glm-5.3|"$TPID"/kimi-k3|"$TPID"/gemma4:31b|ollama-local/*)
        echo "[addon][WARN] provider=third_party but a model slot is still '$_s', which your service almost certainly does not have - set crush_large_model_custom / crush_small_model_custom to $TPID/<model id>" ;;
    esac
  done
fi
apply_model_slot large "$LARGE_MODEL"
apply_model_slot small "$SMALL_MODEL"
# deep model: register if not already registered (register_deep_model in lib.sh)
if [ -n "$DEEP_MODEL" ]; then
  if ! safe_model_id "$DEEP_MODEL"; then
    echo "[addon][WARN] crush_deep_model failed charset validation (letters, digits and . _ : / @ + - only) - deep model not registered" >&2
    DEEP_MODEL=""
  else
    register_deep_model "$DEEP_MODEL"
  fi
fi

if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low|high|max)
      # the DAILY (large) slot only: the helper (small) slot does titles and
      # summaries and keeps its own, cheaper effort
      apply_reasoning_effort large "$EFFORT"
      ;;
    *)
      echo "[addon][WARN] crush_reasoning_effort: '$EFFORT' not low|high|max - ignored"
      ;;
  esac
fi
[ -n "$LARGE_MODEL$SMALL_MODEL$DEEP_MODEL$EFFORT" ] && echo "[addon] model defaults applied from options/env"

# NOTE for crushrc users: the crushrc is BASH - it resolves OLLAMA_API_KEY and
# MCP_TOKEN_<name> from the environment (exported above), so the fetched central
# template keeps working without the addon knowing its internals.

# ── crush sanity + version banner ──────────────────────────────────────
BUILT_VERSION=$(cat /etc/crush-version 2>/dev/null || echo unknown)
# Numeric part only: `crush --version` output wording can change between
# releases, so the update check must not string-compare banner prose with a
# tag (that would re-download the same release on every restart, as root).
BUILT_NUM=$(printf '%s' "$BUILT_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
if crush --version < /dev/null >/dev/null 2>&1; then
  echo "[addon] crush binary OK ($BUILT_VERSION built in)"
else
  echo "[addon][ERROR] crush binary not responding - terminal still starts for debugging"
fi

# Absent/false -> off (matches the config.yaml default since 1.0.33). Never
# rewritten here: a value the user saved is the Supervisor's to keep.
AUTO_UPDATE=$(jq -r '.auto_update_crush // false' /data/options.json)
if [ "$AUTO_UPDATE" = "true" ]; then
  # The tarball is executed as root the moment it is unpacked, so an update is
  # only taken when YOU pin it: crush_update_version (one exact release) and
  # crush_update_sha256 (the sha256 of that release's tarball for this CPU,
  # from the release's checksums.txt). Nothing is learned from the network
  # about what to install, and a version that is not newer than the built one
  # is never installed (no downgrade). Rollback restores the built binary from
  # a LOCAL copy. NB the release asset is crush_<ver>_Linux_<arch>.tar.gz with
  # the binary at crush_<ver>_Linux_<arch>/crush INSIDE the tarball (same as
  # the Dockerfile build path).
  NEW_VER=$(printf '%s' "${CRUSH_UPDATE_VERSION:-$(jq -r '.crush_update_version // ""' /data/options.json)}" | tr -d 'v[:space:]')
  UPD_SHA=$(printf '%s' "${CRUSH_UPDATE_SHA256:-$(jq -r '.crush_update_sha256 // ""' /data/options.json)}" | tr -d '[:space:]')
  case "$NEW_VER" in *[!0-9.]*) NEW_VER="" ;; esac
  if [ -z "$NEW_VER" ] || ! is_sha256 "$UPD_SHA"; then
    echo "[addon][WARN] auto_update_crush is on but crush_update_version / crush_update_sha256 are missing or invalid - update SKIPPED, keeping the built-in crush $BUILT_VERSION"
  elif ! version_gt "$NEW_VER" "$BUILT_NUM"; then
    echo "[addon] crush_update_version $NEW_VER is not newer than the built-in ${BUILT_NUM:-unknown} - nothing to do (downgrades are refused)"
  else
    ARCH=$(uname -m); case "$ARCH" in x86_64) A=x86_64;; aarch64) A=arm64;; *) A=;; esac
    UPD="crush_${NEW_VER}_Linux_${A}.tar.gz"
    UNPACK="/tmp/crush.unpack.$$"
    if [ -n "$A" ] && command -v sha256sum >/dev/null 2>&1 \
       && curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 3 --max-time 30 --max-filesize 104857600 "https://github.com/charmbracelet/crush/releases/download/v${NEW_VER}/${UPD}" -o /tmp/crush.upd 2>/dev/null; then
      if ! sha256_matches /tmp/crush.upd "$UPD_SHA"; then
        echo "[addon][WARN] crush update $NEW_VER HASH MISMATCH: pinned ${UPD_SHA,,}, downloaded $(file_sha256 /tmp/crush.upd) - REFUSED, keeping the built-in crush"
        rm -f /tmp/crush.upd
      elif mkdir -p "$UNPACK" \
           && tar -xzf /tmp/crush.upd -C "$UNPACK" \
           && [ -f "$UNPACK/crush_${NEW_VER}_Linux_${A}/crush" ]; then
        cp -p /usr/local/bin/crush /tmp/crush.prev 2>/dev/null || true
        if [ -f /tmp/crush.prev ] \
           && cp "$UNPACK/crush_${NEW_VER}_Linux_${A}/crush" /usr/local/bin/crush.new \
           && chown root:root /usr/local/bin/crush.new 2>/dev/null \
           && chmod 755 /usr/local/bin/crush.new \
           && mv -f /usr/local/bin/crush.new /usr/local/bin/crush \
           && crush --version < /dev/null >/dev/null 2>&1; then
          echo "[addon] crush updated to $NEW_VER (sha256 matches the pin)"
        else
          echo "[addon][WARN] updated crush fails to run (or no backup could be made) - restoring the built binary from the local backup"
          cp -p /tmp/crush.prev /usr/local/bin/crush 2>/dev/null || true
          chmod +x /usr/local/bin/crush 2>/dev/null || true
          (crush --version < /dev/null >/dev/null 2>&1 \
            || echo "[addon][ERROR] rollback failed - reinstall the add-on to fix the binary")
        fi
      else
        echo "[addon][WARN] crush update $NEW_VER: the archive did not contain the expected binary - keeping the built-in crush"
      fi
    else
      echo "[addon][WARN] crush update $NEW_VER download failed (or unsupported CPU) - keeping the built-in crush"
    fi
    rm -rf "$UNPACK" 2>/dev/null || true
    rm -f /tmp/crush.upd /tmp/crush.chk /tmp/crush.prev /usr/local/bin/crush.new
  fi
  unset NEW_VER UPD_SHA A ARCH UPD UNPACK BUILT_NUM
fi

# ── Web terminal ────────────────────────────────────────────────────────
# One jq spawn for the eight terminal-web options (NUL-delimited, same pattern
# as the model-slot read above). touch_bar uses the if-form, not // : jq's //
# treats an explicit false as unset, and an opt-in toggle must stay falseable.
mapfile -d '' -t -- _topts < <(jq -rj '[.terminal_font_size // 14, .terminal_theme // "dark", (if .session_persistence == null then true else .session_persistence end), (.working_directory // "/homeassistant"), (if .touch_bar == null then true else .touch_bar end), (.touch_bar_offset // 0), (if .touch_bar_debug == null then false else .touch_bar_debug end), (if .terminal_mouse == null then true else .terminal_mouse end), (if .osc52_autocopy == null then false else .osc52_autocopy end)] | .[] | (tostring + "\u0000")' /data/options.json 2>/dev/null)
FONT_SIZE="${_topts[0]}"
# FONT_SIZE is spliced into an UNQUOTED -t token, so force it to digits: the
# jq default only covers a missing key, not a string the operator (or anything
# that can write /data/options.json) sets to shell metacharacters.
case "$FONT_SIZE" in
  ""|*[!0-9]*) FONT_SIZE=14 ;;
esac
THEME="${_topts[1]}"
SESSION_PERSIST="${_topts[2]}"
TOUCHBAR="${_topts[4]}"
TOUCHBAR_OFFSET="${_topts[5]}"
TOUCHBAR_DEBUG="${_topts[6]}"
# osc52_autocopy (default off): may a program in the terminal write the browser
# clipboard without a click? Off = it gets a notice with a Copy button.
_tb_auto=
[ "${CRUSH_OSC52_AUTOCOPY:-${_topts[8]}}" = "true" ] && _tb_auto=1
# terminal_mouse=false -> tmux `mouse off` (read by .tmux.conf), so a plain drag
# selects text in the browser; anything but an explicit false keeps mouse on.
if [ "${_topts[7]}" = "false" ]; then export HASSCRUSH_MOUSE=off; else export HASSCRUSH_MOUSE=on; fi
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
WORKDIR="${_topts[3]}"
# Restrict the agent's cwd to the add-on's mapped roots (same list as DOCS.md).
# Prefix-match alone can be bypassed with traversal (/homeassistant/../root),
# so cd first, then verify the RESOLVED path (pwd -P) against the roots and
# fall back if it lands outside — crush runs as root in this container, so an
# unchecked cwd would expose the whole filesystem to the agent.
if cd "$WORKDIR" 2>/dev/null; then
  case "$(pwd -P)" in
    /homeassistant|/homeassistant/*|/config|/config/*|/share|/share/*|/media|/media/*|/ssl|/ssl/*|/backup|/backup/*) ;;
    *)
      echo "[addon][WARN] working_directory '$WORKDIR' resolves outside the mapped roots (/homeassistant /config /share /media /ssl /backup) - using /homeassistant"
      cd /homeassistant
      ;;
  esac
else
  echo "[addon][WARN] working_directory '$WORKDIR' unusable - using /homeassistant"
  cd /homeassistant
fi

# ── Touch bar (on-screen key bar at the panel bottom; touch_bar option) ──
# Served by handing ttyd a custom index page (ttyd's --index option): the
# build-time-extracted embedded client page with the touch-bar script spliced
# in (touchbar_inject, lib.sh). Every step degrades to the plain terminal -
# the bar is a nicety and must never block the boot or change the transport
# (gate/header unchanged; ttyd still binds 7682 for the healthcheck).
# The page is ALWAYS injected (when the assets exist): besides the bar it
# carries the clipboard helpers (OSC 52 -> browser clipboard, copy-on-select),
# which ttyd's own client lacks. touch_bar=false just tells it to mount no bar.
_tb_index=
if [ -r /usr/local/share/ttyd-index.html ] && [ -r /usr/local/share/touchbar.js ]; then
  _tb_dbg=
  [ "$TOUCHBAR_DEBUG" = "true" ] && _tb_dbg=1
  _tb_nobar=
  [ "$TOUCHBAR" = "true" ] || _tb_nobar=1
  if touchbar_inject /usr/local/share/ttyd-index.html /usr/local/share/touchbar.js "$THEME" /tmp/ttyd-touchbar.html "$TOUCHBAR_OFFSET" "$_tb_dbg" "$_tb_nobar" "$_tb_auto"; then
    _tb_index=/tmp/ttyd-touchbar.html
    if [ "$TOUCHBAR" = "true" ]; then
      echo "[addon] touch bar on: sticky Ctrl/Alt/Tab, momentary Esc/Del/Copy/Paste (offset $(touchbar_offset_clamp "$TOUCHBAR_OFFSET") px); clipboard helpers on"
    else
      echo "[addon] touch bar off; clipboard helpers on"
    fi
  else
    echo "[addon][WARN] web client page injection failed - starting the plain terminal (no OSC 52 copy)"
  fi
else
  echo "[addon][WARN] web client assets missing from image - starting the plain terminal (no OSC 52 copy)"
fi

# Only the Supervisor's ingress proxy may reach the root shell. Two layers:
#  1. ttyd listens on loopback only (TTYD_BACKEND_*, lib.sh); a socat gate on
#     the ingress port relays ONLY connections whose source is the Supervisor
#     ingress address (INGRESS_ADDR, lib.sh) - other containers on the HA
#     network and the LAN are dropped at accept time. (ttyd cannot bind to
#     INGRESS_ADDR itself: that address is the Supervisor container's.)
#  2. defense in depth: ttyd still requires X-Hass-Source, which HA core
#     ingress always stamps; a regression there fails CLOSED (407).
# If the gate dies the panel goes dark (fail closed), never open.
mapfile -t _gate < <(ingress_gate_args)
socat "${_gate[@]}" &
if [ -n "$_tb_index" ]; then
  mapfile -t _ttyd < <(ttyd_args "$FONT_SIZE" "$COLORS" --index "$_tb_index")
else
  mapfile -t _ttyd < <(ttyd_args "$FONT_SIZE" "$COLORS")
fi
# SHELL_CMD is deliberately word-split (command + args).
# shellcheck disable=SC2086
exec ttyd "${_ttyd[@]}" $SHELL_CMD
