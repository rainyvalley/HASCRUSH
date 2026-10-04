# AGENTS.md — HASSCharm

Home Assistant add-on repository: runs [Charm Crush](https://github.com/charmbracelet/crush) (terminal AI coding agent) inside HA, pointed at the owner's own Ollama models. Single add-on repo — everything lives under `charm-crush/`.

## Structure

```
charm-crush/
  config.yaml      # add-on manifest: options + schema + security flags (version bumps here)
  build.yaml       # build image (HA base 3.21) + OCI labels
  Dockerfile       # alpine-based image: ttyd static binary + crush from GH releases + ha CLI
  rootfs/run.sh    # ALL startup logic (388 lines: fetch config, keys, persistence, tmux+ttyd)
  rootfs/root/     # .bashrc / .tmux.conf copied into the image
  translations/en.yaml  # Options-tab labels — CI asserts EVERY option has an entry
  DOCS.md          # Documentation-tab content (mirrors README)
repository.json    # HA add-on repository descriptor
.github/workflows/ci.yml
```

There is no compiled code and no test suite. The repo is: YAML manifests + one big shell script + one Dockerfile.

## Commands

Validation (same checks CI runs — run these before every commit):

```bash
bash -n charm-crush/rootfs/run.sh                 # run.sh syntax
python3 - <<'EOF'                                 # YAML + options/schema/translations completeness
import yaml
c = yaml.safe_load(open('charm-crush/config.yaml'))
t = yaml.safe_load(open('charm-crush/translations/en.yaml'))
assert not [k for k in c['options'] if k not in (c.get('schema') or {})], 'missing schema'
assert not [k for k in c['options'] if k not in (t.get('configuration') or {})], 'missing translations'
EOF
```

Full image build (CI builds both arches with buildx + QEMU; slow):

```bash
docker buildx build --platform linux/amd64 --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21 \
  --build-arg BUILD_ARCH=amd64 -t charm-crush:amd64 charm-crush/
```

Local CI validation needs `pyyaml` (pip install).

## Release process (implicit convention)

Every functional change bumps `version:` in `charm-crush/config.yaml` (patch +0.0.1) in the same commit. Recent commit subjects are `feature summary; bump 1.0.12` style. HA add-ons won't update without a version bump, so never commit a change to `config.yaml`/`run.sh`/`Dockerfile` without one.

## How the add-on works (control flow at start)

`s6-overlay` (pid 1, from the HA base image) runs `rootfs/run.sh` which, in order:

1. Re-exports `HOME`/`USER`/`SHELL` and `S6_KEEP_ENV=1` — s6 strips the env by default; without this crush aborts with "Failed to get user home directory".
2. Supervisor-API self-check: `SUPERVISOR_TOKEN` (injected by HA, never user-set) is re-exported as `HA_TOKEN`; two probe calls print OK/denied into the add-on log.
3. Sourcing `/homeassistant/.crushdata/env` (optional KEY=VALUE defaults).
4. Symlinks `/root/.config/crush` and `/root/.local/share/crush` into `/homeassistant/.crushdata/` for persistence (HA backups include `/homeassistant`).
5. Writes/patches `/homeassistant/.crushdata/CRUSH.md` — the agent-facing guardrails file crush ingests. Marker-based injection (`<!-- hasscrush-limits-start/end -->`) so user edits survive: never rewrite this file wholesale from run.sh; edit the `LIMITS_BODY` heredoc instead.
6. crushrc resolution: `crush_config_url` fetch (sanity-checked with grep for `provider|model add`) over a built-in fallback; the crushrc is a **bash script** that resolves `OLLAMA_API_KEY`/`MCP_TOKEN_<name>` from the environment run.sh exports.
7. Option overrides applied via sed: provider remap (third-party), model slots, reasoning effort, and the `mcp_servers` JSON merge (one option wires ALL MCP servers, tokens exported as `MCP_TOKEN_<name>` env vars, referenced not inlined).
8. Optional crush self-update (with rollback), then `exec ttyd` serving `tmux new-session -A -s crush` on port 7681 (ingress).

Key precedence everywhere: **real environment > env file (/homeassistant/.crushdata/env) > Options tab > central URL > persisted file**.

## Gotchas

- **`init: false` in config.yaml is load-bearing.** s6-overlay must be pid 1; `init: true` re-parents it and the container dies with "can only run as pid 1".
- **No `full_access`/`docker_api` on purpose** — keeps HA's security rating at the hardened default. The CRUSH.md "Hard Limits" block tells the crush agent which denials are by design (hassio paths, `supervisor.*` websockets, docker) so it stops retrying them.
- **Never put a literal API key or private IP in any file.** CI's secret-scan step greps for `sk-ant-oat|sk-or-…|gho_…` plus the author's LAN IP/address patterns (see ci.yml) and fails the build. The default configs are deliberately free of real hosts/keys; secrets come from env/URLs.
- **The fallback crushrc is bash executed by crush, not YAML.** When editing it, remember `: "${VAR:-cmd}"` does NOT assign (comment in run.sh documents this old bug); use `[ -n "$VAR" ] || VAR=...` chains.
- **crushrc model lines need full metadata** — a slot without `--default-max-tokens` breaks session title generation ("max_tokens must be positive, got: 0", seen 2026-09-30). Register models with `model add` *and* set slots with `model large/small`.
- **sed is busybox-safe** in run.sh (no backreferences); key values are never passed through sed (they may contain `/`, `#`) — use grep-out + printf + mv.
- **`HA_URL=http://supervisor` only resolves inside add-ons.** Don't test Supervisor REST from outside.
- **Model lists refresh only on add-on (or crush) restart** — the picker reads the crushrc at load, not the API.
- Config changes to options must update BOTH `options:` and `schema:` in config.yaml (and `translations/en.yaml`) or CI fails.

## The related LAN fleet (context, not part of this repo)

The author runs a crush fleet managed from a separate installer (`/srv/crush/install-crush.sh` on a LAN host, served over HTTP at :8887): `install-crush.sh` installs crush+tmux on bare machines, fetches the central crushrc template, syncs the Ollama Cloud key (`ollama.key` URL) and mem0/vision MCP tokens, and installs a daily `crush-update.timer` systemd unit. Notable bugs fixed there (do not reintroduce): systemd unit `User=` must be the *installing* user, not hardcoded root (a root User= on a machine installed by a non-root user makes the daily timer fail with "No crushrc yet"); crush creates a per-working-directory `.crush/crush.db` sqlite db on first agent run, so running crush in a dir whose `.crush/` belongs to another user fails with `Failed to connect to database: unable to open database file (14)` (fix: `chown -R` the dir or run from elsewhere).

## Related live memory

mem0 long-term memory keyed on the user's email is the shared memory layer (Open WebUI + crush). When picking up new durable facts about the fleet (ports, paths, rotation procedures), store them there.