#!/usr/bin/env bats
# run.sh ordering: the third-party API key is exported as OLLAMA_API_KEY only
# AFTER the Ollama key block, which persists $OLLAMA_API_KEY to ollama.env.
# Exporting it earlier saved the third-party key as the Ollama key.

RUN="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/charm-crush/rootfs/run.sh"

@test "third-party key is exported only after the ollama key block" {
  export_line=$(grep -n 'export OLLAMA_API_KEY="\$TP_KEY"' "$RUN" | cut -d: -f1)
  block_line=$(grep -n '^OPT_KEY=' "$RUN" | cut -d: -f1)
  [ "$(printf '%s\n' "$export_line" | wc -l)" -eq 1 ]
  [ -n "$block_line" ]
  [ "$export_line" -gt "$block_line" ]
}

@test "fallback rc key lookup keeps '=' inside the key value" {
  grep -qF 'cut -s -d= -f2-)' "$RUN"
}
