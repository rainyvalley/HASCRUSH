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
#   MCP_TOKEN_<name>=...  (NOT a token source - mcp_servers entries carry
#                        their own token/token_url; run.sh exports one of
#                        these per entry after resolving it. A manually set
#                        value is only read by a fetched template that
#                        references $MCP_TOKEN_<name> itself)
#   CRUSH_CONFIG_URL=http://my-server/crushrc.template
# Missing file = no defaults set; everything still works from options/schema.
ENV_FILE="$PERSIST_DIR/env"
if [ -r "$ENV_FILE" ]; then
  # Only KEY=VALUE and export KEY=VALUE lines are honored - anything else
  # (shell code, pipes, command substitution) is FILTERED OUT and never runs:
  # a filtered copy is sourced, not the raw file, so a stray or malicious
  # line in this file can never execute as code at startup (this runs as
  # root inside the add-on).
  ENV_CLEAN="$PERSIST_DIR/.env.clean.$$"
  # Value grammar (fail closed - the kept lines are sourced AS BASH):
  #  - name=quoted-value or name=bare-value (the old `"?value"?` accepted an
  #    UNBALANCED trailing quote, which then aborted `.` sourcing under set -e),
  #  - a comment may follow only after real whitespace: `KEY=v#$(cmd)` in an
  #    assignment RHS is NOT a bash comment and would EXECUTE the substitution
  #    when sourced - the old `(#.*)?` alternative let that through.
  ENV_PAT='^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=("[A-Za-z0-9_./:@+%-]*"|[A-Za-z0-9_./:@+%-]+)?([[:space:]]+#.*)?$'
  # (the trailing ? on the value group also keeps a bare `NAME=` line: empty
  # value = explicitly unset, valid)
  grep -E "$ENV_PAT" "$ENV_FILE" > "$ENV_CLEAN" || true
  BAD=$(grep -vE "$ENV_PAT" "$ENV_FILE" || true)
  # Blank lines and #-comments are skipped along with the rest, but they are
  # not actionable - only flag content lines so the boot log stays quiet.
  BAD=$(printf '%s\n' "$BAD" | grep -vE '^[[:space:]]*(#.*)?$' || true)
  if [ -n "$BAD" ]; then
    echo "[addon][WARN] $ENV_FILE has non KEY=VALUE lines - they were SKIPPED (not executed):" >&2
    # Values are ALWAYS masked in the log: a rejected line may still be an
    # attempted key assignment carrying a real secret.
    echo "$BAD" | sed 's/=.*/=<masked>/; s/^/    /' >&2
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
  # Only skip when BOTH markers are present. A start marker without the end
  # one means the block was truncated/escaped after a previous write — re-inject
  # the full block rather than silently skipping: a planted start marker would
  # otherwise suppress the guardrails forever (suppression, not duplication,
  # is the attack; a partial file getting a second start marker is cosmetic).
  if grep -qF "$LIMITS_START" "$CRUSH_MD" && grep -qF "$LIMITS_END" "$CRUSH_MD"; then
    return 0
  fi
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

# ── charset validators for values written into the bash-executed crushrc ──
# The crushrc is a BASH script, so every value printf'd or sed'd into a
# generated line is potential code execution in this add-on (as root).
# Option-/env-sourced values get tight charsets here and are skipped with a
# WARN when they fail - never written. safe_url: http/https only, URL-safe
# chars, excluding the ones that would break the double-quoted crushrc line
# (` $ " \ ) or the #-delimited sed s/// commands some values are fed to
# (& too - it is sed's whole-match in a replacement, and query strings
# rarely appear on these base/token URLs). safe_text: commands/args/model
# ids - rejects the same shell-dangerous set.
safe_url() {
  case "$1" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._~/:?+@,%-]*) return 1 ;;
  esac
  return 0
}
safe_text() {
  # NB the apostrophe is deliberately NOT in the allowed set: generated rc
  # values are wrapped in double quotes inside a sh -c gate body which itself
  # sits inside a SINGLE-quoted rc token - a `'` can escape that outer token
  # and start code injection (reached later when crush executes the rc).
  case "$1" in
    *[!A-Za-z0-9' '._,/@%+=:-]*) return 1 ;;
    *'('*|*'`'*) return 1 ;;
  esac
  return 0
}
# plain-http note (user decision: http stays allowed); $1 = exact warn body,
# $2 = the URL. http carries secrets/writable scripts unencrypted on the wire.
warn_plain_http() { case "$2" in http://*) echo "[addon][WARN] $1; prefer https" >&2 ;; esac; }
# guard a value before it is written into the bash-executed crushrc: when $1 is
# non-empty but fails validator $2, log $3 and return 1; otherwise return 0.
val_check() { if [ -n "$1" ] && ! "$2" "$1"; then echo "[addon][WARN] $3" >&2; return 1; fi; }

# ── crushrc: central template, or a self-contained fallback ────────────
crushrc="$PERSIST_DIR/config/crush/crushrc"
CONFIG_URL="${CRUSH_CONFIG_URL:-$(jq -r '.crush_config_url // ""' /data/options.json)}"
val_check "$CONFIG_URL" safe_url "crush_config_url failed charset validation (must be http/https + URL-safe chars) - ignored" || CONFIG_URL=""
# Plain-HTTP caveat (user decision: http stays allowed): the fetched template
# is a BASH script crush later executes, so tampered-in-transit content runs
# in this add-on as root.
warn_plain_http "crush_config_url uses plain http - the fetched script could be modified in transit on the wire" "$CONFIG_URL"
# Sanity-check the FULL download, not just the first 2 KB: every line is
# executable as bash, so validation must cover the whole file. Size-capped
# at 1 MB (--max-filesize plus an explicit wc -c for chunked/no-length
# servers) so a runaway/infinitely-fed URL cannot fill the tmpfs.
CRUSHRC_FETCHED=0
if [ -n "$CONFIG_URL" ] \
   && curl -fsSL --retry 2 --retry-delay 2 --max-time 10 --max-filesize 1048576 "$CONFIG_URL" -o /tmp/crushrc.new 2>/dev/null \
   && [ "$(wc -c < /tmp/crushrc.new)" -le 1048576 ] \
   && grep -qE '(provider|model) (add|large|small)|crushrc' /tmp/crushrc.new \
   && bash -n /tmp/crushrc.new 2>/dev/null; then
  mv -f /tmp/crushrc.new "$crushrc"   # same-dir move = atomic
  CRUSHRC_FETCHED=1
  echo "[addon] crushrc fetched from the central template: $CONFIG_URL"
else
  # Fail closed: a fetch that failed ANY gate (HTTP/size/content/bash-syntax —
  # `bash -n` catches truncated or garbled bytes before they can ever run) is
  # never applied, and the partial file is never left behind in /tmp.
  rm -f /tmp/crushrc.new
  if [ -n "$CONFIG_URL" ]; then
    echo "[addon][WARN] central crushrc fetch failed validation (HTTP/size/content/bash-syntax) - fetched template NOT applied" >&2
  fi
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

# --discover-models true merges the providers' full catalogs into the picker
# (every ollama.com model the key can call + the whole LAN catalog) - explicit
# `model add` entries below always win over discovered ones. Toggle:
# crush_discover_models option / CRUSH_DISCOVER_MODELS env.
provider add ollama-cloud --type openai-compat --base-url "https://ollama.com/v1" --api-key "$OLLAMA_API_KEY" --discover-models true
if [ -n "$LOCAL_OLLAMA_URL" ]; then
provider add ollama-local --type ollama --base-url "$LOCAL_OLLAMA_URL" --discover-models true
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
if [ -n "$CONFIG_URL" ]; then
  CV_CENTRAL=$(curl -fsSL --max-time 5 "${CONFIG_URL%/*}/config.version" 2>/dev/null | tr -d '[:space:]' | head -c 16 || true)
  case "$CV_CENTRAL" in *[!0-9]*) CV_CENTRAL="" ;; esac
fi
if [ -z "$CONFIG_URL" ]; then
  echo "[addon] crush_config_url unset - no central config-version to check"
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
if [ "$PROVIDER" = "third_party" ]; then
  TP_URL="${THIRD_PARTY_BASE_URL:-$(jq -r '.third_party_base_url // ""' /data/options.json)}"
  TP_KEY="${THIRD_PARTY_API_KEY:-$(jq -r '.third_party_api_key // ""' /data/options.json)}"
  if [ -z "$TP_URL" ] || [ -z "$TP_KEY" ]; then
    echo "[addon][ERROR] provider=third_party but third_party_base_url / third_party_api_key are missing - falling back to ollama"
  elif ! safe_url "$TP_URL"; then
    echo "[addon][WARN] third_party_base_url failed charset validation (http/https + URL-safe chars only) - falling back to ollama" >&2
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

# ── Model auto-discovery: crush_discover_models option / CRUSH_DISCOVER_MODELS env
# The native --discover-models true provider flag (also used by the central
# template) merges the provider's full catalog into the TUI picker; explicit
# `model add` entries win on conflicts. false disables it everywhere (fetched
# templates included); true only ever touches the add-on's own fallback rc -
# a fetched template stays exactly what its author served.
DISCOVER_MODELS="${CRUSH_DISCOVER_MODELS:-$(jq -r '.crush_discover_models // true' /data/options.json)}"
case "$DISCOVER_MODELS" in false|0|no) DISCOVER_MODELS=false ;; *) DISCOVER_MODELS=true ;; esac
if [ "$DISCOVER_MODELS" = false ]; then
  sed -i 's/--discover-models true/--discover-models false/g' "$crushrc"
  echo "[addon] model auto-discovery disabled (crush_discover_models=false) - picker shows only hand-registered models"
elif [ "$CRUSHRC_FETCHED" != "1" ] \
   && grep -q '^# Built-in fallback crushrc' "$crushrc" 2>/dev/null \
   && ! grep -q -- '--discover-models true' "$crushrc" 2>/dev/null; then
  # legacy fallback rc written before discovery: flip it on in place
  sed -i 's#--api-key "\$OLLAMA_API_KEY"$#& --discover-models true#' "$crushrc" 2>/dev/null
  sed -i 's#--type ollama --base-url "\$LOCAL_OLLAMA_URL"$#& --discover-models true#' "$crushrc" 2>/dev/null
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
[ -n "$DISTI_TOKEN" ] && DISTI_CURL=(-H "X-Disti-Token:${DISTI_TOKEN}")
touch "$keyfile"; chmod 600 "$keyfile"
if [ -n "$OPT_KEY" ]; then
  # addon option wins; rewrite the key file DELIBERATELY (not sed: keys may
  # contain '/', '#' or other sed-specials which would corrupt s/// expressions)
  { grep -v '^OLLAMA_API_KEY=' "$keyfile" || true; printf 'OLLAMA_API_KEY=%s\n' "$OPT_KEY"; } > "$keyfile.tmp"
  mv "$keyfile.tmp" "$keyfile"
  chmod 600 "$keyfile"
  echo "[addon][INFO] ollama API key set (env/env-file/option)"
elif [ -n "$KEY_URL" ] && curl -fsSL --max-time 10 --max-filesize 65536 "${DISTI_CURL[@]}" "$KEY_URL" -o /tmp/key.new 2>/dev/null \
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
    echo "[addon][INFO] ollama API key refreshed from $KEY_URL"
  fi
  rm -f /tmp/key.new   # the fetched key never lingers in /tmp
else
  rm -f /tmp/key.new   # cover fetch attempts that failed mid-download too
  [ -s "$keyfile" ] && echo "[addon][INFO] using existing persisted ollama key" \
    || echo "[addon][WARN] no ollama API key found (option, key URL, or persisted file)"
fi
# ── MCP token plumbing (all servers, incl. mem0, via mcp_servers JSON) ──
# Every token is carried by its OWN mcp_servers entry ("token": or
# "token_url":); resolved values are exported as MCP_TOKEN_<name> env vars
# and the crushrc references them, so secrets never land in stored files.
# No per-service option fields exist anymore; the old MEM0_MCP_TOKEN env is
# no longer read.
CR=$(printf '\r')
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
  # swallow=1 while consuming the matched entry's continuation lines; it
  # means "the PREVIOUS line was part of the entry", so a line is swallowed
  # exactly then; the swallow state continues only past lines ending in '\'.
  _mcp_swallow=0
  while IFS= read -r _mcp_line; do
    # tolerate CRLF and trailing whitespace after a continuation backslash
    _mcp_line="${_mcp_line%$CR}"; _mcp_line="${_mcp_line%%[[:space:]]}"
    if [ "$_mcp_swallow" = "0" ]; then
      case "$_mcp_line" in
        "mcp add $1 "*|"mcp add $1")
          # first line of the entry: swallow it; continue swallowing while
          # it ends with backslash (multi-line entry)
          case "$_mcp_line" in *'\') _mcp_swallow=1 ;; *) _mcp_swallow=0 ;; esac
          ;;
        *) printf '%s\n' "$_mcp_line" >> "$_mcp_rm_tmp" ;;
      esac
    else
      case "$_mcp_line" in
        *'\') : ;;                       # pure continuation: swallow
        *) _mcp_swallow=0 ;;             # entry terminator: swallow, done
      esac
    fi
  done < "$crushrc"
  cat "$_mcp_rm_tmp" > "$crushrc" 2>/dev/null && rm -f "$_mcp_rm_tmp" || true
}

mcp_sanitize() {
  # One-time repair for rcs damaged by pre-1.0.14 single-line deletes: those
  # removed only the HEAD line ("mcp add openscad --type stdio") of a
  # backslash-continued entry, orphaning the continuation lines in the
  # persisted crushrc (failures like "mcp add: unknown flag network" /
  # "unknown flag 168.1.252:3010"- the token got split mid-word). Also
  # repairs editor-wrapped tokens inside an entry: while an mcp add chain is
  # open, the next line (even a bare value like "168.1.252:3010") JOINS the
  # previous line seamlessly - reproducing the original unbroken token.
  _mcp_sz_tmp=/tmp/mcp_sanitize.$$
  : > "$_mcp_sz_tmp"
  # open=1 while inside an mcp add entry chain; prev_bs=1 when the previous
  # line ended with a continuation backslash
  _mcp_sz_open=0
  _mcp_sz_prev_bs=0
  while IFS= read -r _mcp_line; do
    # tolerate '\r' (CRLF-persisted rcs) before matching
    _mcp_line="${_mcp_line%$CR}"
    case "$_mcp_line" in
      "mcp add "*)
        _mcp_sz_open=1
        _mcp_sz_prev_bs=0
        printf '%s\n' "$_mcp_line" >> "$_mcp_sz_tmp"
        ;;
      [[:space:]]*"--args "*|[[:space:]]*"--command "*|[[:space:]]*"--timeout "*|\
[[:space:]]*"--header "*|[[:space:]]*"--url "*|[[:space:]]*"--env "*)
        # mcp-exclusive flag fragment: kept ONLY while an mcp add chain is
        # open (normal multi-line entry); with NO open head it is an orphan
        # from a pre-1.0.14 single-line delete -> drop it
        if [ "$_mcp_sz_open" = "1" ]; then
          printf '%s\n' "$_mcp_line" >> "$_mcp_sz_tmp"
        else
          echo "[addon][INFO] removed orphaned mcp flag fragment: $_mcp_line"
        fi ;;
      *)
        if [ "$_mcp_sz_open" = "1" ] && [ "$_mcp_sz_prev_bs" = "1" ]; then
          # continuation line: join onto the previous kept line (the
          # previous backslash was a seamless wrap - e.g. a token split
          # mid-word like "TCP:192." / "168.1.252:3010")
          _mcp_sz_last=$(tail -1 "$_mcp_sz_tmp" | sed 's/[[:space:]]*\\$//')
          sed -i '$d' "$_mcp_sz_tmp"
          printf '%s%s\n' "$_mcp_sz_last" "$_mcp_line" >> "$_mcp_sz_tmp"
        else
          _mcp_sz_open=0
          printf '%s\n' "$_mcp_line" >> "$_mcp_sz_tmp"
        fi ;;
    esac
    case "$(printf '%s' "$_mcp_line" | sed 's/[[:space:]]*$//')" in
      *'\') _mcp_sz_prev_bs=1 ;;
      *) _mcp_sz_prev_bs=0 ;;
    esac
  done < "$crushrc"
  mv "$_mcp_sz_tmp" "$crushrc" 2>/dev/null || true
}

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
      MCP_TOK=$(curl -fsSL --max-time 10 --max-filesize 65536 "${DISTI_CURL[@]}" "$3" 2>/dev/null | tr -d '[:space:]' | head -c 4096)
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
# (mcp_remove above), never other servers a central template registers.
# Empty/unset or INVALID JSON = no changes; template lines stay authoritative
# - including a template's mem0 line for crush_config_url users.
MCP_JSON="${MCP_SERVERS:-$(jq -r '.mcp_servers // "[]"' /data/options.json 2>/dev/null)}"
mcp_sanitize
# one validity check shared by the three uses below (loop, invalid-JSON warn,
# legacy mem0 scan): did jq parse the text as a JSON array?
MCP_JSON_VALID=0
if echo "$MCP_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  MCP_JSON_VALID=1
fi
if [ "$MCP_JSON_VALID" = 1 ] && [ "$MCP_JSON" != "[]" ]; then
  MCP_COUNT=$(echo "$MCP_JSON" | jq 'length')
  _mcp_idx=0
  while [ "$_mcp_idx" -lt "$MCP_COUNT" ]; do
    MCP_ENTRY=$(echo "$MCP_JSON" | jq -c ".[$_mcp_idx]")
    _mcp_idx=$((_mcp_idx + 1))
    MCP_NAME=$(echo "$MCP_ENTRY" | jq -r '.name // ""' | tr -d '\r\n ')
    MCP_URL=$(echo "$MCP_ENTRY" | jq -r '.url // ""' | tr -d '\r\n')
    MCP_CMD=$(echo "$MCP_ENTRY" | jq -r '.command // ""' | tr -d '\r\n')
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
    mcp_remove "$MCP_NAME"
    if [ -n "$MCP_URL" ]; then
      MCP_TOK=$(echo "$MCP_ENTRY" | jq -r '.token // ""' | tr -d '\r\n[:space:]')
      MCP_TOK_URL=$(echo "$MCP_ENTRY" | jq -r '.token_url // ""' | tr -d '\r\n')
      mcp_token_fetch "$MCP_NAME" "$MCP_TOK" "$MCP_TOK_URL"
      if [ -n "$MCP_TOK" ]; then
        export "MCP_TOKEN_${MCP_NAME}=${MCP_TOK}"
        printf 'mcp add %s --type http --url "%s" --header Authorization "Bearer $MCP_TOKEN_%s"\n' "$MCP_NAME" "$MCP_URL" "$MCP_NAME" >> "$crushrc"
      else
        # no token resolves: still wire the server (LAN servers may not need
        # auth) - same posture as mem0's token fetch failure
        printf 'mcp add %s --type http --url "%s"\n' "$MCP_NAME" "$MCP_URL" >> "$crushrc"
        [ -n "$MCP_TOK_URL" ] && echo "[addon][WARN] mcp_servers '$MCP_NAME': token_url yielded nothing - added without auth header"
      fi
    elif [ -n "$MCP_CMD" ]; then
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
      MCP_TOK=$(echo "$MCP_ENTRY" | jq -r '.token // ""' | tr -d '\r\n[:space:]')
      MCP_TOK_URL=$(echo "$MCP_ENTRY" | jq -r '.token_url // ""' | tr -d '\r\n')
      mcp_token_fetch "$MCP_NAME" "$MCP_TOK" "$MCP_TOK_URL"
      MCP_ARGS_LINE=""
      # gate wrapper body (sh code run by `sh -c`): each command word gets a
      # double quote so a value with spaces stays one argv element. safe_text
      # rejects ALL quote/backslash/dollar characters, so nothing an operator
      # pastes can ever break out of those quotes or the rc's outer
      # single-quoted token below.
      MCP_GATE="exec \"${MCP_CMD}\""
      MCP_NARGS=$(echo "$MCP_ENTRY" | jq '.args // [] | length')
      _arg_idx=0
      _mcp_args_ok=1
      while [ "$_arg_idx" -lt "$MCP_NARGS" ]; do
        # one --args token per element: crush exec's argv directly, no shell
        # splitting - values may contain spaces/slashes safely. SPACE form is
        # required: crush's shell-config flag engine (internal/shellconfig/
        # flags.go, stable v0.88->main) only matches the exact token --args;
        # the =-form dies with "mcp add: unknown flag --args=...". Dash-prefixed
        # values (--network, --rm) are consumed verbatim by nextArg, no quoting
        # needed.
        # a paste with an editor line-wrap can embed raw \n/\r inside a
        # value; strip them so the generated rc line never breaks mid-token
        _mcp_arg=$(echo "$MCP_ENTRY" | jq -r ".args[$_arg_idx]" | tr -d '\r\n')
        if ! safe_text "$_mcp_arg"; then
          echo "[addon][WARN] mcp_servers '$MCP_NAME': arg #$_arg_idx failed charset validation (shell metachars not allowed) - entry skipped" >&2
          _mcp_args_ok=0
          break
        fi
        MCP_ARGS_LINE="$MCP_ARGS_LINE --args $_mcp_arg"
        MCP_GATE="$MCP_GATE \"$_mcp_arg\""
        _arg_idx=$((_arg_idx + 1))
      done
      [ "$_mcp_args_ok" = "1" ] || continue
      MCP_TIMEOUT=$(echo "$MCP_ENTRY" | jq -r '.timeout // ""' | tr -d '\r\n[:space:]')
      case "$MCP_TIMEOUT" in
        "") ;;
        # numeric only: the timeout is printf'd bare into the rc line
        *[!0-9]*) echo "[addon][WARN] mcp_servers '$MCP_NAME': timeout must be numeric - entry skipped" >&2; continue ;;
      esac
      if [ -n "$MCP_TOK" ]; then
        export "MCP_TOKEN_${MCP_NAME}=${MCP_TOK}"
        # single-quoted rc token around the sh -c body keeps the variable
        # UNEXPANDED in the stored rc (resolved when crush launches the
        # server). The printf "%s\n" newline inside is written as literal
        # \n here and becomes a real newline inside the inner sh.
        MCP_RC="mcp add $MCP_NAME --type stdio --command sh --args -c --args '{ printf \"%s\\n\" \"\$MCP_TOKEN_${MCP_NAME}\"; $MCP_GATE; }'"
      else
        MCP_RC="mcp add $MCP_NAME --type stdio --command \"$MCP_CMD\"$MCP_ARGS_LINE"
        # no token resolves: still wire the server (a bare relay is the
        # wrong posture for a gated bridge, so say so) - same posture as a
        # tokenless http entry
        [ -n "$MCP_TOK_URL" ] && echo "[addon][WARN] mcp_servers '$MCP_NAME': token_url yielded nothing - added WITHOUT the token gate (a gated bridge will close this relay)" >&2
      fi
      [ -n "$MCP_TIMEOUT" ] && MCP_RC="$MCP_RC --timeout $MCP_TIMEOUT"
      printf '%s\n' "$MCP_RC" >> "$crushrc"
    else
      echo "[addon][WARN] mcp_servers '$MCP_NAME': neither url nor command set - skipped"
    fi
  done
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
apply_model_slot() {
  # $1 = slot (large|small), $2 = chosen model id ("" = keep config's choice).
  # Replaces ONLY the model id, preserving any trailing flags (effort etc.).
  [ -n "$2" ] || return 0
  if ! safe_text "$2"; then
    echo "[addon][WARN] crush_${1}_model failed charset validation (shell metachars not allowed) - slot left unchanged" >&2
    return 0
  fi
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
  if ! safe_text "$DEEP_MODEL"; then
    echo "[addon][WARN] crush_deep_model failed charset validation (shell metachars not allowed) - deep model not registered" >&2
    DEEP_MODEL=""
  else
    ESC=$(printf '%s' "$DEEP_MODEL" | sed 's/[.[\\*+^$()|?{]/\\&/g')
    grep -qE "^model add .*/$ESC( |$)" "$crushrc" 2>/dev/null || \
      printf '\nmodel add %s --can-reason true --reasoning-effort max\n' "$DEEP_MODEL" >> "$crushrc"
  fi
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

AUTO_UPDATE=$(jq -r '.auto_update_crush // false' /data/options.json)
if [ "$AUTO_UPDATE" = "true" ]; then
  # The tarball is executed as root the moment it is unpacked, so the archive
  # is verified against the release's own checksums.txt (exact-second-field
  # awk match, same pattern as the Dockerfile build path) BEFORE it is
  # swapped in. NEW_VER is charset-checked [0-9.] before it reaches a URL
  # (it comes from a GitHub JSON reply, not operator input - but it keys a
  # URL we curl as root). Rollback restores the built binary from a LOCAL
  # copy: the old code re-downloaded it over the network, which can fail and
  # strand a broken binary after the failed upgrade already ran. NB the
  # release asset is crush_<ver>_Linux_<arch>.tar.gz with the binary at
  # crush_<ver>_Linux_<arch>/crush INSIDE the tarball (same as the Dockerfile
  # build path) - the old run.sh queried a flat crush_<ver>_x86_64.tar.gz
  # upstream never published, so this path 404'd and never ran at all.
  NEW_VER=$(curl -fsSL --max-time 15 https://api.github.com/repos/charmbracelet/crush/releases/latest 2>/dev/null | jq -r .tag_name | tr -d v | head -c 32)
  case "$NEW_VER" in
    ""|*[!0-9.]*) NEW_VER="" ;;   # empty/garbage tag: skip, keep the built version
  esac
  if [ -n "$NEW_VER" ] && [ "$NEW_VER" != "$BUILT_NUM" ]; then
    ARCH=$(uname -m); case "$ARCH" in x86_64) A=x86_64;; aarch64) A=arm64;; *) A=;; esac
    UPD="crush_${NEW_VER}_Linux_${A}.tar.gz"
    UNPACK="/tmp/crush.unpack.$$"
    if [ -n "$A" ] && command -v sha256sum >/dev/null 2>&1 \
       && curl -fsSL --max-time 30 --max-filesize 104857600 "https://github.com/charmbracelet/crush/releases/download/v${NEW_VER}/${UPD}" -o /tmp/crush.upd 2>/dev/null \
       && curl -fsSL --max-time 15 --max-filesize 65536 "https://github.com/charmbracelet/crush/releases/download/v${NEW_VER}/checksums.txt" -o /tmp/crush.chk 2>/dev/null \
       && EXPECTED=$(awk -v f="$UPD" '$2 == f {print $1; exit}' /tmp/crush.chk 2>/dev/null) \
       && [ -n "$EXPECTED" ] \
       && [ "$(sha256sum /tmp/crush.upd | cut -d' ' -f1)" = "$EXPECTED" ] \
       && mkdir -p "$UNPACK" \
       && tar -xzf /tmp/crush.upd -C "$UNPACK" \
       && [ -f "$UNPACK/crush_${NEW_VER}_Linux_${A}/crush" ]; then
      cp -p /usr/local/bin/crush /tmp/crush.prev 2>/dev/null || true
      if cp "$UNPACK/crush_${NEW_VER}_Linux_${A}/crush" /usr/local/bin/crush.new \
         && chown root:root /usr/local/bin/crush.new 2>/dev/null \
         && chmod 755 /usr/local/bin/crush.new \
         && mv -f /usr/local/bin/crush.new /usr/local/bin/crush \
         && crush --version < /dev/null >/dev/null 2>&1; then
        echo "[addon] crush updated to $NEW_VER (checksum verified)"
      else
        echo "[addon][WARN] updated crush fails to run - restoring the built binary from the local backup"
        cp -p /tmp/crush.prev /usr/local/bin/crush 2>/dev/null || true
        chmod +x /usr/local/bin/crush 2>/dev/null || true
        (crush --version < /dev/null >/dev/null 2>&1 \
          || echo "[addon][ERROR] rollback failed - reinstall the add-on to fix the binary")
      fi
      rm -rf "$UNPACK"; rm -f /tmp/crush.upd /tmp/crush.chk /tmp/crush.prev /usr/local/bin/crush.new
    else
      echo "[addon][WARN] crush update ${BUILT_VERSION} -> ${NEW_VER:-unknown} SKIPPED (download or checksum verification failed) - keeping the built binary"
      rm -rf "$UNPACK" 2>/dev/null || true; rm -f /tmp/crush.upd /tmp/crush.chk /tmp/crush.prev /usr/local/bin/crush.new
    fi
  else
    echo "[addon] crush $BUILT_VERSION is current"
  fi
  unset NEW_VER A ARCH UPD UNPACK EXPECTED BUILT_NUM
fi

# ── Web terminal ────────────────────────────────────────────────────────
FONT_SIZE=$(jq -r '.terminal_font_size // 14' /data/options.json)
# FONT_SIZE is spliced into an UNQUOTED -t token, so force it to digits: the
# jq default only covers a missing key, not a string the operator (or anything
# that can write /data/options.json) sets to shell metacharacters.
case "$FONT_SIZE" in
  ""|*[!0-9]*) FONT_SIZE=14 ;;
esac
THEME=$(jq -r '.terminal_theme // "dark"' /data/options.json)
SESSION_PERSIST=$(jq -r 'if .session_persistence == null then true else .session_persistence end' /data/options.json)
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
WORKDIR=$(jq -r '.working_directory // "/homeassistant"' /data/options.json)
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

# Direct http://<host>:7681 hits from the LAN must NOT reach the root shell:
# ttyd listens on 0.0.0.0 and the LAN route bypasses HA auth entirely.
# HA core ingress ALWAYS stamps X-Hass-Source: core.ingress on both the HTTP
# and WebSocket paths (homeassistant/components/hassio ingress _init_header),
# and browsers cannot forge that header cross-origin (not CORS-safelisted),
# so gating on it keeps the ingress panel working while direct :7681 traffic
# gets HTTP 407 / a refused WS handshake. If a HA core regression ever drops
# the header the panel fails CLOSED (407), not silently open.
exec ttyd --port 7681 --writable --ping-interval 30 --max-clients 5 \
    --auth-header X-Hass-Source \
    -t "fontSize=$FONT_SIZE" \
    -t fontFamily=Monaco,Consolas,monospace \
    -t scrollback=20000 \
    -t "theme=$COLORS" \
    $SHELL_CMD