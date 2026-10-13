#!/usr/bin/env bats
# provider_reset / provider_remap (rootfs/lib.sh): the third-party remap of
# the persisted crushrc must be undone on every start, so a provider switch
# (or a changed base URL) never leaves the rc pointing at a stale host that
# would then receive a different key.

load 'test_helper'
setup() {
  setup_tmp
  cat > "$crushrc" <<'RC'
provider add ollama-cloud --type openai-compat --base-url "https://ollama.com/v1" --api-key "$OLLAMA_API_KEY" --discover-models true
model add ollama-cloud/glm-5.3-flash --name "GLM 5.3 Flash" --default-max-tokens 131072
model large ollama-cloud/glm-5.3-flash --reasoning-effort high
RC
  cp "$crushrc" "$TMP/orig"
}
teardown() { teardown_tmp; }

@test "remap points the provider and model ids at the third-party host" {
  provider_remap openai-compat-3p "https://api.example.com/v1"
  grep -qF 'provider add openai-compat-3p --type openai-compat --base-url "https://api.example.com/v1"' "$crushrc"
  grep -qxF 'model large openai-compat-3p/glm-5.3-flash --reasoning-effort high' "$crushrc"
  ! grep -qF 'ollama-cloud' "$crushrc"
}

@test "reset after a remap restores the original rc byte for byte" {
  provider_remap openai-compat-3p "https://api.example.com/v1"
  provider_reset openai-compat-3p
  cmp "$crushrc" "$TMP/orig"
}

@test "switching back to ollama no longer targets the old third-party host" {
  provider_remap openai-compat-3p "https://old.example.com/v1"
  provider_reset openai-compat-3p      # next start, provider=ollama
  ! grep -qF 'old.example.com' "$crushrc"
}

@test "a changed third-party base URL replaces the old one on the next start" {
  provider_remap openai-compat-3p "https://old.example.com/v1"
  provider_reset openai-compat-3p
  provider_remap openai-compat-3p "https://new.example.com/v1"
  grep -qF -- '--base-url "https://new.example.com/v1"' "$crushrc"
  ! grep -qF 'old.example.com' "$crushrc"
}

@test "reset is a no-op on an rc that was never remapped" {
  provider_reset openai-compat-3p
  cmp "$crushrc" "$TMP/orig"
}

@test "reset leaves other providers' base URLs alone" {
  printf 'provider add ollama-local --type ollama --base-url "http://192.0.2.10:11434/v1"\n' >> "$crushrc"
  provider_remap openai-compat-3p "https://api.example.com/v1"
  provider_reset openai-compat-3p
  grep -qxF 'provider add ollama-local --type ollama --base-url "http://192.0.2.10:11434/v1"' "$crushrc"
}

@test "tp_model_id: an ollama-cloud/ option id follows the third-party remap" {
  [ "$(tp_model_id ollama-cloud/glm-5.3-flash openai-compat-3p)" = "openai-compat-3p/glm-5.3-flash" ]
}

@test "tp_model_id: ids on other providers and bare ids are untouched" {
  [ "$(tp_model_id ollama-local/qwen3-vl:4b-instruct openai-compat-3p)" = "ollama-local/qwen3-vl:4b-instruct" ]
  [ "$(tp_model_id gpt-5 openai-compat-3p)" = "gpt-5" ]
  [ "$(tp_model_id '' openai-compat-3p)" = "" ]
}

@test "remap + default slot option keeps the large slot on the registered provider" {
  provider_remap openai-compat-3p "https://api.example.com/v1"
  apply_model_slot large "$(tp_model_id ollama-cloud/glm-5.3-flash openai-compat-3p)"
  grep -qxF 'model large openai-compat-3p/glm-5.3-flash --reasoning-effort high' "$crushrc"
}

# ── original base URL is recorded, not assumed ───────────────────────────

@test "a template ollama-cloud line with a non-default URL survives remap + reset" {
  cat > "$crushrc" <<'RC'
provider add ollama-cloud --type openai-compat --base-url "https://proxy.example.com/v1" --api-key "$OLLAMA_API_KEY"
model large ollama-cloud/glm-5.3-flash
RC
  cp "$crushrc" "$TMP/orig2"
  provider_remap openai-compat-3p "https://api.example.com/v1"
  provider_reset openai-compat-3p
  cmp "$crushrc" "$TMP/orig2"
}

@test "remap leaves a non-default URL in place (only the default is swapped)" {
  printf 'provider add ollama-cloud --type openai-compat --base-url "https://proxy.example.com/v1"\n' > "$crushrc"
  provider_remap openai-compat-3p "https://api.example.com/v1"
  grep -qF -- '--base-url "https://proxy.example.com/v1"' "$crushrc"
}

@test "remap records a marker; reset removes it" {
  provider_remap openai-compat-3p "https://api.example.com/v1"
  grep -qxF '# charm-crush:base-url-was https://ollama.com/v1' "$crushrc"
  provider_reset openai-compat-3p
  ! grep -qF 'charm-crush:base-url-was' "$crushrc"
}

@test "repeated remap/reset cycles do not stack markers" {
  provider_remap openai-compat-3p "https://a.example.com/v1"
  provider_reset openai-compat-3p
  provider_remap openai-compat-3p "https://b.example.com/v1"
  [ "$(grep -c 'charm-crush:base-url-was' "$crushrc")" -eq 1 ]
  provider_reset openai-compat-3p
  cmp "$crushrc" "$TMP/orig"
}

@test "an rc remapped by an older version (no marker) still gets the default URL back" {
  cat > "$crushrc" <<'RC'
provider add openai-compat-3p --type openai-compat --base-url "https://old.example.com/v1" --api-key "$KEY"
model large openai-compat-3p/glm-5.3-flash
RC
  provider_reset openai-compat-3p
  grep -qF 'provider add ollama-cloud --type openai-compat --base-url "https://ollama.com/v1"' "$crushrc"
  ! grep -qF 'old.example.com' "$crushrc"
}

@test "a recorded URL with & and spaces-free odd chars is restored verbatim" {
  printf 'provider add ollama-cloud --type openai-compat --base-url "https://h.example.com/v1?a=1&b=2"\n' > "$crushrc"
  cp "$crushrc" "$TMP/orig3"
  provider_remap openai-compat-3p "https://api.example.com/v1"
  provider_reset openai-compat-3p
  cmp "$crushrc" "$TMP/orig3"
}
