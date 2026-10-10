#!/usr/bin/env bats
# apply_model_slot: the `sed` on the synthetic crushrc (large/small slots,
# run.sh globals per lib.sh's header comment).

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

@test "apply_model_slot replaces the model id of the named slot, preserving trailing flags" {
  printf 'provider add ollama-cloud --type openai-compat\nmodel large glm-4.7 --reasoning-effort high\nmodel small glm-4.5-air\n' > "$crushrc"
  apply_model_slot large glm-5.3
  grep -qxF 'model large glm-5.3 --reasoning-effort high' "$crushrc"
  grep -qxF 'model small glm-4.5-air' "$crushrc"
}

@test "apply_model_slot appends the slot line when it is absent" {
  printf 'provider add ollama-cloud --type openai-compat\n' > "$crushrc"
  apply_model_slot small qwen3-vl:4b-instruct
  grep -qxF 'model small qwen3-vl:4b-instruct' "$crushrc"
  grep -qF 'provider add ollama-cloud' "$crushrc"
}

@test "apply_model_slot with an empty model id changes nothing" {
  printf 'model large glm-5.3\n' > "$crushrc"
  apply_model_slot large ""
  grep -qxF 'model large glm-5.3' "$crushrc"
}

@test "apply_model_slot warns on but does not write a non-[A-Za-z0-9 .:/+_-] model id" {
  printf 'model large glm-5.3\n' > "$crushrc"
  before="$(cat "$crushrc")"
  run apply_model_slot large 'weird(id)'
  [ "$status" -eq 0 ]   # skipped with a WARN, not a hard failure
  [[ "$output" == *"failed charset validation"* ]]
  [[ "$(cat "$crushrc")" == "$before" ]]
}