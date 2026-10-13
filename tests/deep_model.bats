#!/usr/bin/env bats
# register_deep_model (rootfs/lib.sh): idempotent registration of the deep
# model option; must not append a duplicate line on every start.

load 'test_helper'
setup() { setup_tmp; }
teardown() { teardown_tmp; }

count() { grep -c '^model add' "$crushrc" || true; }

@test "a full provider/id already registered is NOT appended again (default option)" {
  printf 'model add ollama-cloud/glm-5.3 --name "GLM 5.3" --context-window 1000000\n' > "$crushrc"
  register_deep_model ollama-cloud/glm-5.3
  register_deep_model ollama-cloud/glm-5.3
  [ "$(count)" = 1 ]
}

@test "a bare id matches a provider-prefixed registration" {
  printf 'model add ollama-cloud/glm-5.3 --name "GLM 5.3"\n' > "$crushrc"
  register_deep_model glm-5.3
  [ "$(count)" = 1 ]
}

@test "an indented registration (template if-block) counts" {
  printf 'if true; then\n  model add ollama-cloud/glm-5.3 --name x\nfi\n' > "$crushrc"
  register_deep_model ollama-cloud/glm-5.3
  [ "$(count)" = 0 ]   # the only registration is the indented one
  ! grep -q '^model add ollama-cloud/glm-5.3 --can-reason' "$crushrc"
}

@test "a missing model is appended exactly once across repeated starts" {
  printf 'model add ollama-cloud/glm-5.3-flash --name x\n' > "$crushrc"
  register_deep_model ollama-cloud/glm-5.3
  register_deep_model ollama-cloud/glm-5.3
  grep -qxF 'model add ollama-cloud/glm-5.3 --can-reason true --reasoning-effort max' "$crushrc"
  [ "$(count)" = 2 ]
}

@test "a prefix-sharing id (glm-5.3-flash) does not count as glm-5.3" {
  printf 'model add ollama-cloud/glm-5.3-flash --name x\n' > "$crushrc"
  register_deep_model ollama-cloud/glm-5.3
  grep -qxF 'model add ollama-cloud/glm-5.3 --can-reason true --reasoning-effort max' "$crushrc"
}
