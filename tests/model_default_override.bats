#!/usr/bin/env bats
# The one-time move to ollama-cloud/deepseek-v4.1-flash:1017.
# /data/options.json is the Supervisor's snapshot (regenerated every start),
# so the override is written once into the add-on's env file, whose CRUSH_*
# defaults outrank the Configuration tab on later boots. These pin the shape
# of that block in run.sh; the env-file grammar itself is covered by env_pat.

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUN="$REPO/charm-crush/rootfs/run.sh"

@test "run.sh carries the :1017 default and a one-time marker" {
  grep -qF 'MODEL_DEFAULT_ID="ollama-cloud/deepseek-v4.1-flash:1017"' "$RUN"
  grep -qF 'MODEL_DEFAULT_MARKER="$PERSIST_DIR/.model-default-1017"' "$RUN"
  # the block runs only while the marker is absent
  grep -qF 'if [ "$TP_ACTIVE" != 1 ] && [ ! -e "$MODEL_DEFAULT_MARKER" ]; then' "$RUN"
}

@test "the override is saved in the env file, once" {
  grep -qF '( umask 077; {' "$RUN"
  grep -qF '} >> "$ENV_FILE" )' "$RUN"
  grep -qF ': > "$MODEL_DEFAULT_MARKER"' "$RUN"
  # no per-start state machine left over from the earlier design
  ! grep -qF 'MODEL_STATE=' "$RUN"
  ! grep -qF 'model_default_action' "$RUN"
}

@test "each slot's CRUSH_* default is written for large, small and deep" {
  grep -qF 'large) _md_var=CRUSH_LARGE_MODEL ;;' "$RUN"
  grep -qF 'small) _md_var=CRUSH_SMALL_MODEL ;;' "$RUN"
  grep -qF 'deep)  _md_var=CRUSH_DEEP_MODEL ;;' "$RUN"
  grep -qF '${_md_var}=${MODEL_DEFAULT_ID}' "$RUN"
}

@test "an operator-supplied CRUSH_* value is never overwritten" {
  grep -qF '[ -n "${!_md_var:-}" ] && continue' "$RUN"
}

@test "config.yaml offers the :1017 model in all three picklists" {
  CFG="$REPO/charm-crush/config.yaml"
  for slot in large small deep; do
    grep -qE "^  crush_${slot}_model: list\\(.*ollama-cloud/deepseek-v4\\.1-flash:1017" "$CFG"
  done
  grep -qF 'crush_large_model: "ollama-cloud/deepseek-v4.1-flash:1017"' "$CFG"
}

@test "a build push bumps the add-on version automatically" {
  W="$REPO/.github/workflows/version-bump.yml"
  [ -f "$W" ]
  grep -qF 'contents: write' "$W"
  grep -qF 'Bump HASSCrush to ' "$W"
  # the repo rule: never persist credentials in a checkout
  grep -qF 'persist-credentials: false' "$W"
}
