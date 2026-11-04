#!/usr/bin/env bats
# model_default_action: the one-time move to deepseek-v4.1-flash:1017.
# Pure helper (lib.sh) - state present(0|1), forced id, saved value, recorded
# value -> force | keep | release. run.sh does the file I/O around it.

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

FORCED="ollama-cloud/deepseek-v4.1-flash:1017"

@test "no state yet: force, whatever the saved value is" {
  [ "$(model_default_action 0 "$FORCED" glm-5.3-flash "")" = force ]
  [ "$(model_default_action 0 "$FORCED" ollama-local/qwen3-vl:4b-instruct "")" = force ]
  [ "$(model_default_action 0 "$FORCED" "" "")" = force ]
}

@test "state present and the saved value already is the default: keep" {
  [ "$(model_default_action 1 "$FORCED" "$FORCED" glm-5.3)" = keep ]
}

@test "state present and the saved value is still the recorded old one: force" {
  [ "$(model_default_action 1 "$FORCED" glm-5.3-flash glm-5.3-flash)" = force ]
}

@test "state present, saved value changed after the override: release" {
  [ "$(model_default_action 1 "$FORCED" glm-5.3 glm-5.3-flash)" = release ]
  [ "$(model_default_action 1 "$FORCED" ollama-local/qwen3-vl:4b-instruct glm-5.3)" = release ]
}

@test "state present but no recorded value: release rather than fight the user" {
  [ "$(model_default_action 1 "$FORCED" glm-5.3 "")" = release ]
}

@test "run.sh records the state next to the crush data and honours CRUSH_* env" {
  RUN="$BATS_TEST_DIRNAME/../charm-crush/rootfs/run.sh"
  grep -q 'MODEL_DEFAULT_ID="ollama-cloud/deepseek-v4.1-flash:1017"' "$RUN"
  grep -q 'MODEL_STATE="$PERSIST_DIR/model-default-1017"' "$RUN"
  # env-set slots are a per-run operator choice
  grep -q '_md_env=${CRUSH_LARGE_MODEL:-}' "$RUN"
  # third-party providers are remapped and must not be forced back
  grep -q 'if \[ "$TP_ACTIVE" != 1 \]; then' "$RUN"
}
