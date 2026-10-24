#!/bin/bash
# lib.sh - pure helpers for charm-crush rootfs/run.sh.
#
# Sourced (never executed) by run.sh - which is copied NEXT TO this file in
# the image (/usr/local/bin/lib.sh) - and by the bats unit suite (tests/).
# Everything here is string-or-file in / string-out-or-exit-code: no network,
# no /data reads, no side effects beyond the files a function is handed.
# Globals these helpers read (set by run.sh, or by tests):
#   $crushrc    - path of the bash crushrc being edited (mcp_*, apply_model_slot)
#   $CRUSH_MD, $LIMITS_START/$LIMITS_END/$LIMITS_BODY (inject_limits)
# shellcheck disable=SC2154  # those globals are the caller's state, by design

# ── ENV_PAT: the env-file value grammar (fail closed) ────────────────────
# The kept lines are sourced AS BASH, so the pattern below decides what may
# execute at startup:
#  - name=quoted-value or name=bare-value (the old `"?value"?` accepted an
#    UNBALANCED trailing quote, which then aborted `.` sourcing under set -e),
#  - a comment may follow only after real whitespace: `KEY=v#$(cmd)` in an
#    assignment RHS is NOT a bash comment and would EXECUTE the substitution
#    when sourced - the old `(#.*)?` alternative let that through,
#  - values may also use `=` `,` `~` `?` (plain assignment text in bash, never
#    code), spaces inside double quotes, or a single-quoted string with no
#    `'` in it (bash treats it as fully literal, so JSON for MCP_SERVERS fits).
#  - the NAME is checked separately by env_name_ok / env_file_clean below.
# shellcheck disable=SC2034  # ENV_PAT is consumed by run.sh's env-file grep (and tests)
ENV_PAT='^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=("[A-Za-z0-9_./:@+%=,~? -]*"|'"'"'[^'"'"']*'"'"'|[A-Za-z0-9_./:@+%=,~?-]+)?([[:space:]]+#.*)?$'
# (the trailing ? on the value group also keeps a bare `NAME=` line: empty
# value = explicitly unset, valid)

# ── charset validators (safe_url / safe_text) and val_check ──────────────
# Values written into the bash-executed crushrc are potential code execution
# in this add-on (as root). Option-/env-sourced values get tight charsets
# here and are skipped with a WARN when they fail - never written.
# safe_url: http/https only, URL-safe chars, excluding the ones that would
# break the double-quoted crushrc line (` $ " \ ) or the #-delimited sed
# s/// commands some values are fed to (& too - it is sed's whole-match in a
# replacement, and query strings rarely appear on these base/token URLs).
# safe_text: commands/args/model ids - rejects the same shell-dangerous set.
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
# safe_model_id: model ids are ONE word in the rc (`model large <id>`), so no
# spaces: an id like `x --base-url http://evil` would otherwise add flags.
safe_model_id() {
  case "$1" in
    ""|*[!A-Za-z0-9._:/@+-]*) return 1 ;;
  esac
  return 0
}
# guard a value before it is written into the bash-executed crushrc: when $1 is
# non-empty but fails validator $2, log $3 and return 1; otherwise return 0.
val_check() { if [ -n "$1" ] && ! "$2" "$1"; then echo "[addon][WARN] $3" >&2; return 1; fi; }

# ── env-file name allow-list + filter ────────────────────────────────────
# The env file is sourced with `set -a`, so every name it sets is exported to
# crush and everything crush starts. A free name list would let the file set
# LD_PRELOAD, BASH_ENV, PATH, IFS, SUPERVISOR_TOKEN, HA_URL ... Only the names
# this add-on documents are honored; everything else is skipped with a warning.
env_name_ok() {
  case "$1" in
    OLLAMA_API_KEY|OLLAMA_KEY_URL|LOCAL_OLLAMA_URL|DISTI_TOKEN|MCP_SERVERS) return 0 ;;
    MCP_TOKEN_*|THIRD_PARTY_*|CRUSH_*) return 0 ;;
  esac
  return 1
}

# env_file_clean SRC DST: write the lines of SRC that match ENV_PAT AND set an
# allowed name to DST (this is what run.sh sources). Every other content line
# (blank lines and #-comments are ignored) is described on stdout, one line
# each, with the value never shown: `NAME=<masked>`, or for a line with no `=`
# only its length (a bare pasted key must not reach the log).
env_file_clean() {
  local line trimmed name
  : > "$2"
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in ""|"#"*) continue ;; esac
    if [[ $line =~ $ENV_PAT ]]; then
      name=$trimmed
      if [[ $trimmed =~ ^export[[:space:]]+(.*)$ ]]; then name=${BASH_REMATCH[1]}; fi
      name=${name%%=*}
      if env_name_ok "$name"; then
        printf '%s\n' "$line" >> "$2"
      else
        printf '%s=<masked> (name not allowed)\n' "$name"
      fi
    elif [[ $trimmed == *=* ]]; then
      printf '%s=<masked>\n' "${trimmed%%=*}"
    else
      printf '<%d characters, no "=">\n' "${#trimmed}"
    fi
  done < "$1"
}

# ── log-safe URLs ────────────────────────────────────────────────────────
# redact_url URL: scheme://host[:port]/path with any user:password@ part and
# any ?query or #fragment removed (those carry credentials). Log this, never
# the raw value.
redact_url() {
  local u=$1 q="" scheme rest auth
  case "$u" in *\?*|*\#*) q='?<hidden>' ;; esac
  u=${u%%\?*}; u=${u%%#*}
  scheme=${u%%://*}; rest=${u#*://}
  auth=${rest%%/*}
  printf '%s://%s%s%s' "$scheme" "${auth##*@}" "${rest#"$auth"}" "$q"
}

# curl_guard URL: set the CURL_GUARD array for a fetch of URL. A redirect may
# never leave the URL's own scheme family: an https URL stays on https (no
# downgrade to http), an http one may move to http or https. At most 2 hops.
curl_guard() {
  case "$1" in
    https://*) CURL_GUARD=(--proto '=https' --proto-redir '=https' --max-redirs 2) ;;
    *)         CURL_GUARD=(--proto '=http,https' --proto-redir '=http,https' --max-redirs 2) ;;
  esac
}

# ── mcp stdio --args fragment ────────────────────────────────────────────
# mcp_arg_fragment ARG: print ` --args "ARG"` for the generated rc line. The
# rc is split into words by crush, so the value must be double-quoted to stay
# ONE argument when it holds a space. Empty or unsafe values return 1 (an
# empty arg would swallow the next flag). safe_text already forbids `"`.
mcp_arg_fragment() {
  [ -n "$1" ] || return 1
  safe_text "$1" || return 1
  printf ' --args "%s"' "$1"
}

# ── CRUSH.md guardrail injection ─────────────────────────────────────────
# Needs run.sh globals: $CRUSH_MD, $LIMITS_START, $LIMITS_END, $LIMITS_BODY.
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

# ── crushrc surgery (mcp_remove / mcp_sanitize) ──────────────────────────
# Both rewrite the file named by the global $crushrc in place.
# tolerate CRLF-persisted rcs when matching.
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
  # the `|| [ -n ... ]` guard: bash read returns nonzero on a final line with
  # no trailing newline and the while body would silently DROP it - a crushrc
  # whose last line is `fi` (the central template ends without \n) would lose
  # it on every pass and leave a dangling `if` ("if' statement must end with
  # fi" at crush config load)
  while IFS= read -r _mcp_line || [ -n "$_mcp_line" ]; do
    # tolerate CRLF and trailing whitespace after a continuation backslash
    _mcp_line="${_mcp_line%$CR}"; _mcp_line="${_mcp_line%%[[:space:]]}"
    if [ "$_mcp_swallow" = "0" ]; then
      # match a leading-whitespace-stripped copy: template entries inside an
      # `if` block are indented, and raw-line [[:space:]] glob arms are
      # unreliable against them (matching on the raw line either missed the
      # entry and left a duplicate, or ate the head as an "orphan fragment")
      _mcp_stripped="${_mcp_line#"${_mcp_line%%[![:space:]]*}"}"
      case "$_mcp_stripped" in
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
  # the `|| [ -n ... ]` guard: bash read returns nonzero on a final line with
  # no trailing newline and the while body would silently DROP it - a crushrc
  # whose last line is `fi` (the central template ends without \n) would lose
  # it on every pass and leave a dangling `if` ("if' statement must end with
  # fi" at crush config load)
  while IFS= read -r _mcp_line || [ -n "$_mcp_line" ]; do
    # tolerate '\r' (CRLF-persisted rcs) before matching
    _mcp_line="${_mcp_line%$CR}"
    # match a leading-whitespace-stripped copy: indented entries (e.g. a
    # template entry inside an `if` block) are still mcp add heads, and
    # raw-line [[:space:]] glob arms are unreliable against them - an
    # indented `mcp add ollama ... --args ...` head once matched the
    # fragment arms and was deleted as an "orphan", unregistering the
    # guarded entry. Original indentation is preserved in the output.
    _mcp_stripped="${_mcp_line#"${_mcp_line%%[![:space:]]*}"}"
    case "$_mcp_stripped" in
      "mcp add "*)
        _mcp_sz_open=1
        _mcp_sz_prev_bs=0
        printf '%s\n' "$_mcp_line" >> "$_mcp_sz_tmp"
        ;;
      "--args "*|"--command "*|"--timeout "*|\
"--header "*|"--url "*|"--env "*)
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

# ── MCP token env var name ───────────────────────────────────────────────
# Server names may contain '-' (run.sh accepts [A-Za-z0-9_-]), env var names
# may not: `export MCP_TOKEN_home-assistant=...` fails, which under run.sh's
# set -e aborted the whole boot, and the rc's $MCP_TOKEN_home-assistant
# expanded as $MCP_TOKEN_home followed by "-assistant". Map '-' to '_'.
mcp_token_var() { printf 'MCP_TOKEN_%s' "${1//-/_}"; }

# '-' and '_' both map onto '_', so two DIFFERENT server names can land on one
# variable (a-b and a_b -> MCP_TOKEN_a_b): the second export would silently
# overwrite the first and the wrong token would go to the wrong server.
# mcp_token_claim records which server owns each variable for this run;
# $1 = server name. Returns 1 (and warns) when a DIFFERENT name already owns
# the mapped variable - run.sh then skips that entry rather than send it a
# token meant for another server. The same name twice is not a collision.
# mcp_token_claims_reset starts a fresh run (run.sh calls it before its loop).
MCP_TOKVAR_OWNERS=""
mcp_token_claims_reset() { MCP_TOKVAR_OWNERS=""; }
mcp_token_claim() {
  _tc_var=$(mcp_token_var "$1")
  while IFS= read -r _tc_line; do
    case "$_tc_line" in
      "$_tc_var="*)
        if [ "${_tc_line#*=}" != "$1" ]; then
          echo "[addon][WARN] mcp_servers: '$1' and '${_tc_line#*=}' both map to \$${_tc_var} - token collision, '$1' skipped (rename one of them)" >&2
          return 1
        fi
        return 0 ;;
    esac
  done <<< "$MCP_TOKVAR_OWNERS"
  MCP_TOKVAR_OWNERS="${MCP_TOKVAR_OWNERS}${_tc_var}=$1"$'\n'
  return 0
}

# ── mcp_servers entry parsing ────────────────────────────────────────────
# One jq spawn per entry for every field. $1 = one entry's JSON text; result
# in the global array _mf (NUL-delimited read, so values may hold spaces):
#   _mf[0]=name [1]=url [2]=command [3]=token [4]=token_url [5]=timeout
#   [6]=argsok (1 = "args" absent or an array, 0 = present but NOT an array)
#   [7..]=args, one element each (empty strings kept, spaces kept)
# Embedded NULs are dropped so a value can never shift into the next field.
# Callers apply their own per-field strips and charset validation.
mcp_parse_entry() {
  mapfile -d '' -t -- _mf < <(printf '%s' "$1" | jq -j '
    [(.name // ""), (.url // ""), (.command // ""), (.token // ""),
     (.token_url // ""), (.timeout // ""),
     (if (.args // []) | type == "array" then 1 else 0 end)]
    + (.args // [] | if type == "array" then . else [] end)
    | .[] | (tostring | gsub("\u0000"; "")) + "\u0000"' 2>/dev/null)
}

# ── model slot rewiring ──────────────────────────────────────────────────
# Needs the global $crushrc (set by run.sh / tests).
apply_model_slot() {
  # $1 = slot (large|small), $2 = chosen model id ("" = keep config's choice).
  # Replaces ONLY the model id, preserving any trailing flags (effort etc.).
  [ -n "$2" ] || return 0
  if ! safe_model_id "$2"; then
    echo "[addon][WARN] crush_${1}_model failed charset validation (letters, digits and . _ : / @ + - only) - slot left unchanged" >&2
    return 0
  fi
  if grep -qE "^model $1 " "$crushrc" 2>/dev/null; then
    sed -i "s#^model $1 [^ ]*#model $1 $2#" "$crushrc"
  else
    printf '\nmodel %s %s\n' "$1" "$2" >> "$crushrc"
  fi
}
# ── third-party provider remap ───────────────────────────────────────────
# Needs the global $crushrc. $1 = the third-party provider id run.sh uses.
# The remap rewrites the PERSISTED rc, which is kept across starts (fallback
# rc, or a template kept after a failed fetch). Without an undo, switching
# provider back to ollama - or changing third_party_base_url - left the rc
# pointing at the OLD third-party host while run.sh exported a DIFFERENT key
# into it (the Ollama key, or the new third-party key): a credential sent to
# a host the operator no longer configured. provider_reset restores the
# ollama-cloud line first, so every start remaps from a clean state.
# provider_remap records the line's ORIGINAL base URL in a marker comment
# line just above it; provider_reset restores exactly that URL (so a template
# whose ollama-cloud line carries a non-default URL is not clobbered) and
# deletes the marker. An rc remapped by an older add-on version has no marker;
# for those the old assumption applies (the URL was https://ollama.com/v1).
PROVIDER_URL_MARKER='# charm-crush:base-url-was '
provider_reset() {
  grep -qF -- "$1" "$crushrc" 2>/dev/null || return 0
  _pr_url=$(sed -n "s/^${PROVIDER_URL_MARKER}//p" "$crushrc" | head -n 1)
  [ -n "$_pr_url" ] || _pr_url="https://ollama.com/v1"
  _pr_tmp="$crushrc.tmp.$$"
  # awk, not sed: the recorded URL is template text (any chars); ENVIRON
  # passes it without escape processing, and substr() splicing avoids sub()'s
  # special handling of & and backslash in the replacement
  PR_ID="$1" PR_URL="$_pr_url" awk '
    BEGIN { u = ENVIRON["PR_URL"]; id = "provider add " ENVIRON["PR_ID"] }
    index($0, id) && match($0, /--base-url "[^"]*"/) {
      $0 = substr($0, 1, RSTART - 1) "--base-url \"" u "\"" substr($0, RSTART + RLENGTH)
    }
    { print }' "$crushrc" > "$_pr_tmp" && cat "$_pr_tmp" > "$crushrc"
  rm -f "$_pr_tmp"
  sed -i -e "\|^${PROVIDER_URL_MARKER}|d" \
    -e "s#provider add $1#provider add ollama-cloud#" -e "s#$1/#ollama-cloud/#g" "$crushrc"
}
# $1 = third-party provider id, $2 = base URL (caller has safe_url-checked
# it: no # & \ " $ or backtick, so it is inert in the s### replacement and in
# the double-quoted rc token).
provider_remap() {
  # marker first (records the ollama-cloud line's current base URL), then the
  # rename + replace of the default URL
  _pr_tmp="$crushrc.tmp.$$"
  PR_MARK="$PROVIDER_URL_MARKER" awk '
    /^[[:space:]]*provider add ollama-cloud([[:space:]]|$)/ && match($0, /--base-url "[^"]*"/) {
      url = substr($0, RSTART + 12, RLENGTH - 13)
      print ENVIRON["PR_MARK"] url
    }
    { print }' "$crushrc" > "$_pr_tmp" && cat "$_pr_tmp" > "$crushrc"
  rm -f "$_pr_tmp"
  sed -i "s#provider add ollama-cloud#provider add $1#; s#ollama-cloud/#$1/#g" "$crushrc"
  sed -i "s#--base-url \"https://ollama.com/v1\"#--base-url \"$2\"#" "$crushrc"
}
# Model ids from options/env name the ollama-cloud provider by default; when
# the third-party remap is active they must follow it, or the slot is set to
# a provider the rc no longer registers. $1 = model id, $2 = provider id.
tp_model_id() {
  case "$1" in
    ollama-cloud/*) printf '%s/%s' "$2" "${1#ollama-cloud/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── deep model registration ──────────────────────────────────────────────
# Needs the global $crushrc. $1 = model id (caller has safe_text-checked it).
# Appends a `model add` for $1 unless the rc already registers it, under
# either the full id or a bare id after some provider prefix. The old check
# was `^model add .*/ID`, which demands a '/' BEFORE the whole id: a full id
# like ollama-cloud/glm-5.3 (the option default) never matched its own
# registration, so the line was appended again on EVERY start, and the late
# metadata-less re-registration followed the rc's full one. Indented lines
# (template `if` blocks) count as registered too.
register_deep_model() {
  _deep_esc=$(printf '%s' "$1" | sed 's/[.[\\*+^$()|?{]/\\&/g')
  grep -qE "^[[:space:]]*model add (.*/)?$_deep_esc( |$)" "$crushrc" 2>/dev/null || \
    printf '\nmodel add %s --can-reason true --reasoning-effort max\n' "$1" >> "$crushrc"
}

# ── ttyd / ingress gate ──────────────────────────────────────────────────
# The Supervisor's ingress proxy lives at a fixed address on the hassio
# network and is the ONLY legitimate client of this add-on's ingress port.
# That address belongs to the SUPERVISOR container, not to this one, so ttyd
# cannot bind to it (bind(2) -> EADDRNOTAVAIL); the gate is therefore a
# source-address allowlist on the listener the Supervisor connects to.
INGRESS_ADDR=172.30.32.2    # Supervisor ingress proxy (fixed by the Supervisor)
INGRESS_PORT=7681           # config.yaml ingress_port - what the Supervisor dials
TTYD_BACKEND_ADDR=127.0.0.1 # ttyd itself is loopback-only
TTYD_BACKEND_PORT=7682      # loopback port ttyd really listens on

# Prints the socat argv (one word per line) of the gate: accept only
# $INGRESS_ADDR on $INGRESS_PORT and relay raw TCP (HTTP + WebSocket) to ttyd.
ingress_gate_args() {
  printf '%s\n' \
    "TCP4-LISTEN:${INGRESS_PORT},fork,reuseaddr,range=${INGRESS_ADDR}/32" \
    "TCP4:${TTYD_BACKEND_ADDR}:${TTYD_BACKEND_PORT}"
}

# Prints the ttyd argv (one word per line) up to and including the shell
# command. $1 font size, $2 colour theme string, rest = shell command words.
# Listens on loopback only; --auth-header stays as defense in depth.
ttyd_args() {
  _ta_font=$1 _ta_colors=$2
  shift 2
  printf '%s\n' \
    --interface "$TTYD_BACKEND_ADDR" --port "$TTYD_BACKEND_PORT" \
    --writable --ping-interval 30 --max-clients 5 \
    --auth-header X-Hass-Source \
    -t "fontSize=${_ta_font}" \
    -t fontFamily=Monaco,Consolas,monospace \
    -t macOptionClickForcesSelection=true \
    -t scrollback=20000 \
    -t "theme=${_ta_colors}" \
    "$@"
}

# ── touch bar (web-terminal key bar, touch_bar option) ─────────────────────
# The add-on can serve ttyd a CUSTOM index page (ttyd 1.7+ --index): the page
# generated here is ttyd's own embedded client page with the touch-bar script
# spliced in before </body>. The bar (rootfs/touchbar.js, copied to
# /usr/local/share/) adds Ctrl/Alt/Tab (latching) and Esc/Del/Paste (one-shot)
# for touch screens, composing latches at the WebSocket send layer.
#
# touchbar_inject SRC_HTML BAR_JS THEME OUT_HTML [OFFSET] [DEBUG]
#   SRC = ttyd's embedded client page (extracted at BUILD time by the
#         Dockerfile from the pinned binary), BAR_JS = touchbar.js,
#   THEME = dark|light (mismatching values fall back to dark),
#   OUT = generated page,
#   OFFSET = optional integer px added to the keyboard lift (touch_bar_offset),
#   DEBUG = "1" draws the viewport diagnostic line (touch_bar_debug),
#   NOBAR = "1" keeps only the always-on clipboard helpers and mounts no bar
#           (touch_bar off), so OSC 52 copy still works without the bar.
# Pure file -> file: no network, no /data. Fails (rc 1) if inputs are missing
# or unreadable, if SRC already carries this add-on's prelude (never inject
# twice), or if the spliced output lacks the prelude marker (then OUT is
# removed). The splice point search is inside the WHOLE page string, not
# line-by-line, so a minified single-line page still splices correctly; when
# </body> is absent, </html> is tried, then the prelude is appended.
touchbar_inject() {
  _ti_src=$1 _ti_bar=$2 _ti_theme=$3 _ti_out=$4
  [ -n "$_ti_src" ] && [ -r "$_ti_src" ] || return 1
  [ -n "$_ti_bar" ] && [ -r "$_ti_bar" ] || return 1
  [ -n "$_ti_out" ] || return 1
  case "$_ti_theme" in dark|light) ;; *) _ti_theme=dark ;; esac
  _ti_off=$(touchbar_offset_clamp "${5:-0}")
  _ti_dbg=
  [ "${6:-}" = "1" ] && _ti_dbg=',"debug":1'
  [ "${7:-}" = "1" ] && _ti_dbg="$_ti_dbg"',"bar":0'
  [ "${8:-}" = "1" ] && _ti_dbg="$_ti_dbg"',"autocopy":1'
  grep -q '__HASSBAR' "$_ti_src" 2>/dev/null && return 1
  awk -v theme="$_ti_theme" -v off="$_ti_off" -v dbg="$_ti_dbg" '
    NR==FNR { if (NR > 1) bar = bar "\n"; bar = bar $0; next }
    { page = page $0 "\n" }
    END {
      pre = "<script>window.__HASSBAR={\"theme\":\"" theme "\",\"offset\":" off dbg "};</script>" \
            "<script>" bar "</script>"
      i = index(page, "</body>")
      if (i == 0) i = index(page, "</html>")
      if (i > 0) {
        printf "%s", substr(page, 1, i - 1) pre substr(page, i)
      } else {
        printf "%s", page pre
      }
    }
  ' "$_ti_bar" "$_ti_src" > "$_ti_out"
  grep -q 'window\.__HASSBAR={"theme"' "$_ti_out" 2>/dev/null || { rm -f "$_ti_out"; return 1; }
}

# touchbar_offset_clamp VALUE -> prints an integer in [-400, 400].
# touch_bar_offset nudges the bar against phones/browsers that report a
# keyboard height we cannot derive exactly (a resting black band under the
# keys = negative, keys hidden behind the keyboard = positive). Anything not
# a plain integer (or out of range) becomes 0 / a clamped value - the value is
# spliced into the generated page, so it must never carry other characters.
touchbar_offset_clamp() {
  case "${1:-}" in
    '') echo 0; return 0 ;;
    -*) _to_neg=1; _to_n=${1#-} ;;
    *) _to_neg=0; _to_n=$1 ;;
  esac
  case "$_to_n" in
    ''|*[!0-9]*) echo 0; return 0 ;;
  esac
  [ "${#_to_n}" -le 4 ] || { echo 0; return 0; }
  _to_n=$((10#$_to_n))
  [ "$_to_n" -le 400 ] || _to_n=400
  if [ "$_to_n" -eq 0 ]; then echo 0; return 0; fi
  if [ "$_to_neg" = "1" ]; then echo "-$_to_n"; else echo "$_to_n"; fi
}

# apply_reasoning_effort SLOT EFFORT: set --reasoning-effort EFFORT on the
# `model SLOT` line of $crushrc (replacing any earlier value). Only the slot
# named is touched: run.sh passes `large`, so the cheap helper (`small`) keeps
# its own effort.
apply_reasoning_effort() {
  local slot=$1 effort=$2 line clean
  line=$(grep -E "^model ${slot} " "$crushrc" | head -1 || true)
  [ -n "$line" ] || return 0
  clean=$(printf '%s\n' "$line" | sed "s/[[:space:]]*--reasoning-effort [a-z]*//")
  sed -i "s#^${line}\$#${clean} --reasoning-effort ${effort}#" "$crushrc" 2>/dev/null || true
}

# discover_models_apply true|false: flip every `--discover-models` flag in the
# add-on's own rc. `true` also repairs a legacy fallback rc written before the
# flag existed (appends it to the provider lines).
discover_models_apply() {
  if [ "$1" = false ]; then
    sed -i 's/--discover-models true/--discover-models false/g' "$crushrc"
  else
    sed -i 's/--discover-models false/--discover-models true/g' "$crushrc"
    if ! grep -q -- '--discover-models true' "$crushrc"; then
      sed -i 's#--api-key "\$OLLAMA_API_KEY"$#& --discover-models true#' "$crushrc"
      sed -i 's#--type ollama --base-url "\$LOCAL_OLLAMA_URL"$#& --discover-models true#' "$crushrc"
    fi
  fi
}

# ── pinned hashes and versions ───────────────────────────────────────────
# is_sha256 VALUE: exactly 64 hex characters (either case).
is_sha256() { [[ $1 =~ ^[0-9A-Fa-f]{64}$ ]]; }

# file_sha256 FILE: print the lowercase hex SHA-256 of FILE.
file_sha256() { sha256sum "$1" | cut -d' ' -f1 | tr 'A-F' 'a-f'; }

# sha256_matches FILE EXPECTED: 0 only if EXPECTED is a valid hash equal to
# FILE's SHA-256 (case-insensitive).
sha256_matches() {
  is_sha256 "$2" || return 1
  [ "$(file_sha256 "$1")" = "$(printf '%s' "$2" | tr 'A-F' 'a-f')" ]
}

# version_gt A B: 0 when dotted-number version A is strictly newer than B.
# Both must be digits and dots only; anything else returns 1 (no update).
version_gt() {
  local IFS=. a b i x y
  case "$1$2" in ""|*[!0-9.]*) return 1 ;; esac
  [ -n "$1" ] && [ -n "$2" ] || return 1
  read -ra a <<< "$1"; read -ra b <<< "$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x=$((10#${a[i]:-0})); y=$((10#${b[i]:-0}))
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

# ── one-time move of the persisted data ──────────────────────────────────
# persist_migrate OLD NEW MARKER: before 1.0.51 the add-on kept its data in
# OLD (inside the shared Home Assistant config folder, which other add-ons
# can write). It now lives in NEW (the add-on's private folder). The first
# start copies OLD to NEW without overwriting anything already in NEW,
# leaves OLD in place, and writes MARKER so it never runs twice. Prints what
# it did (one line per step) for the add-on log.
persist_migrate() {
  local old=$1 new=$2 marker=$3
  [ -e "$marker" ] && return 0
  if [ ! -d "$old" ]; then return 0; fi
  mkdir -p "$new" || { echo "[addon][ERROR] cannot create $new - old data in $old not migrated"; return 1; }
  if cp -a -n "$old"/. "$new"/ 2>/dev/null; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$marker"
    echo "[addon][NOTICE] data migrated: copied $old to $new (nothing in $new was overwritten)"
    echo "[addon][NOTICE] the old copy in $old was left in place; delete it once you have checked the new one. It is no longer read."
  else
    echo "[addon][ERROR] copy from $old to $new failed - will retry on the next start"
    return 1
  fi
}
