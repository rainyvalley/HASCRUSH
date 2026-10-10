#!/usr/bin/env bats
# The legacy `: "${OLLAMA_API_KEY:?...}"` crushrc migration. This block is
# inline in rootfs/run.sh (not extractable - it sits inside the template
# write's else-branch), so these tests replicate the EXACT two statements
# run.sh runs (grep at run.sh:305, sed at run.sh:306) against a synthetic
# legacy rc, pinning the patterns so they cannot drift.

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

legacy_grep()  { grep -q '^: "${OLLAMA_API_KEY:?' "$crushrc" 2>/dev/null; }
legacy_sed()   { sed -i '/^: "${OLLAMA_API_KEY:?/d' "$crushrc"; }

@test "legacy migration marker matches a pre-fix rc that assigned the key via ': ?'" {
  printf 'model large glm-5.3\n: "${OLLAMA_API_KEY:?unattended crushrc}"\nprovider add ollama-cloud\n' > "$crushrc"
  legacy_grep
}

@test "legacy migration removes only the marker line, keeping the rest of the rc" {
  printf 'model large glm-5.3\n: "${OLLAMA_API_KEY:?unattended crushrc}"\nprovider add ollama-cloud\n' > "$crushrc"
  legacy_sed
  ! grep -qF 'OLLAMA_API_KEY' "$crushrc"
  grep -qxF 'model large glm-5.3' "$crushrc"
  grep -qxF 'provider add ollama-cloud' "$crushrc"
}

@test "a fixed rc no longer matches the migration marker (idempotent)" {
  printf 'model large glm-5.3\nprovider add ollama-cloud\nexport OLLAMA_API_KEY="x"\n' > "$crushrc"
  if legacy_grep; then fail 'false positive on a migrated rc'; fi
}

@test "an OLLAMA_API_KEY mention elsewhere does not false-positive the marker" {
  printf 'export OLLAMA_API_KEY="x"\nmcp add mem0 --type http --url "http://m"\n' > "$crushrc"
  if legacy_grep; then fail 'matched an unrelated OLLAMA_API_KEY line'; fi
}