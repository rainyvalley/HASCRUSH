# AGENTS.md — HASCRUSH (repo) — add-on display name: **HASSCrush**

(The repo/folder is `HASCRUSH`; every user-visible listing uses **HASSCrush** — correct casing, never "HASSCRUSH" in prose/UI.)

Home Assistant add-on repository: runs [Charm Crush](https://github.com/charmbracelet/crush) (terminal AI coding agent) inside HA, pointed at the owner's own Ollama models. Single add-on repo — everything lives under `charm-crush/`.

## Structure

```
charm-crush/
  config.yaml      # add-on manifest: options + schema + security flags (version bumps here)
  build.yaml       # build image (HA base 3.21) + OCI labels
  Dockerfile       # alpine-based image: ttyd + crush + ha CLI, each pinned and sha256-verified
  rootfs/run.sh    # startup logic (fetch config, keys, supervisor-token recovery, persistence, tmux+ttyd)
  rootfs/lib.sh    # pure helpers sourced by run.sh and by the bats suite (see below)
  rootfs/touchbar.js # client-side touch bar, spliced into a ttyd --index page (touch_bar option)
  rootfs/root/     # .bashrc / .tmux.conf copied into the image
  translations/en.yaml  # Options-tab labels - CI asserts EVERY option has an entry
  DOCS.md          # Documentation-tab content (mirrors README.md; keep the two in sync)
  CHANGELOG.md     # Changelog-tab content (Keep a Changelog; gated by CI, see Release process)
tests/             # bats unit suites for rootfs/lib.sh and the changelog gate (+ test_helper.bash)
.github/scripts/   # check_changelog.sh (changelog gate)
repository.json    # HA add-on repository descriptor
.github/workflows/ci.yml
```

`rootfs/lib.sh` holds everything that can be tested without a running add-on: string-or-file in, string-or-exit-code out, no network, no `/data` reads. It is copied next to `run.sh` in the image (`/usr/local/bin/lib.sh`) and sourced by it. Contents: the env-file grammar (`ENV_PAT`), the env-file name allow-list and filter (`env_name_ok`, `env_file_clean`), URL redaction (`redact_url`) and curl redirect limits (`curl_guard`), charset validators (`safe_url`, `safe_text`, `val_check`), CRUSH.md guardrail injection, crushrc surgery (`mcp_remove`, `mcp_sanitize`), the `mcp_servers` entry parser (`mcp_parse_entry`), MCP token variable naming and collision detection (`mcp_token_var`, `mcp_token_claim`), model slot rewiring, and the third-party provider remap/reset. New logic that can be pure belongs in lib.sh with a bats test, not inline in run.sh.

MCP token variables: each `mcp_servers` entry's token is exported as `MCP_TOKEN_<name>` with `-` mapped to `_` (`home-assistant` -> `MCP_TOKEN_home_assistant`). Names that map to the same variable (`a-b` / `a_b`) collide; the later token-bearing entry is skipped with a warning.

## Tests

`tests/*.bats` source the real `charm-crush/rootfs/lib.sh` (via `tests/test_helper.bash`) and drive it with synthetic `$crushrc` / `$CRUSH_MD` fixtures in a temp dir. Run them with `bats tests/` (install bats via your package manager). Fixtures use RFC 5737 documentation addresses (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and `*.invalid` / `*.example.com` hosts - never a real or RFC 1918 address (the secret scan rejects those).

## Commands

Validation (same checks CI runs - run these before every commit):

```bash
bash -n charm-crush/rootfs/run.sh && bash -n charm-crush/rootfs/lib.sh
shellcheck -S error charm-crush/rootfs/run.sh charm-crush/rootfs/lib.sh
bats tests/
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

## CI gates (`.github/workflows/ci.yml`)

`validate` job: YAML + schema/translations completeness; `bash -n` and `shellcheck -S error` on run.sh + lib.sh (a full advisory report runs too); `bats tests/`; hadolint (checksum-verified binary, rules waived in `charm-crush/.hadolint.yaml`); actionlint (checksum-verified); the **changelog gate** (`.github/scripts/check_changelog.sh`: `charm-crush/CHANGELOG.md` needs `## [Unreleased]` and a `## [<config.yaml version>]` section; local files only, tested by `tests/changelog_gate.bats`); the **version-bump recency gate** (run.sh, lib.sh and the Dockerfile must not have a commit newer than the last config.yaml commit - see Release process); frenck's official add-on linter; and the **secret scan** (API-key prefixes and RFC 1918 addresses in every tracked text file, `.github` included). `build` job (both arches, QEMU): image build, binary smoke test (crush, ttyd, ha), and a boot-surface smoke test that boots the image with a stub `/data/options.json` (third-party provider, mem0, a hyphenated http entry, a stdio entry) and asserts on the GENERATED crushrc.

Third-party actions are pinned by commit SHA (tag kept as a trailing comment); downloaded binaries (ttyd, crush, ha CLI, hadolint, actionlint) are verified by sha256. Bumping any of them means updating the pin and the hash together.

## Release process (implicit convention)

Every functional change bumps `version:` in `charm-crush/config.yaml` (patch +0.0.1) in the same commit. Recent commit subjects are `feature summary; bump 1.0.12` style. HA add-ons won't update without a version bump, so never commit a change to `config.yaml`/`run.sh`/`lib.sh`/`Dockerfile` without one.

**Every version bump also ships its changelog entry, in the same change.** HA shows `charm-crush/CHANGELOG.md` in the add-on's Changelog tab. Keep a Changelog format: while working, describe user-facing changes under `## [Unreleased]`; when bumping `version:`, move them under a new `## [x.y.z] - YYYY-MM-DD` heading (newest first, `### Added/Changed/Fixed/Security/Removed`, written for add-on users, no secrets or private addresses - the secret scan covers it) and leave an empty `## [Unreleased]` on top. CI fails if the config.yaml version has no matching section or `## [Unreleased]` is missing. This is in addition to, not instead of, the recency rule below.

**A number that has already shipped doesn't count again.** Supervisor compares the version *string* and nothing else — tree contents, commit dates and file hashes are all invisible to it. So a merge, rebase or fast-forward carrying several commits releases every one of them under whichever number the last bumping commit set, and any commit landing after that without its own bump is permanently unreachable: the store and the install both read the same number, no delta is offered, and no amount of store reloading or repository re-adding can surface it. That is exactly how 1.0.28 failed — `c5e1dac` bumped to it, then `b7354c7` (run.sh option handling + the `mcp_servers` loop) and `051733a` landed unbumped on top, so installs built from any of those three trees reported 1.0.28 and the two later run.sh fixes could not be delivered at all; only `01fcace` (bumping to 1.0.29) did. Sanity check before pushing — the `config.yaml` line must be the *newer* of the two; if `run.sh` names a commit that came after it, the version is stale:

```bash
git log --oneline -1 -- charm-crush/config.yaml    # last bump
git log --oneline -1 -- charm-crush/rootfs/run.sh charm-crush/rootfs/lib.sh charm-crush/Dockerfile  # last code change
```

## How the add-on works (control flow at start)

`s6-overlay` (pid 1, from the HA base image) runs `rootfs/run.sh` which, in order:

1. Re-exports `HOME`/`USER`/`SHELL` and `S6_KEEP_ENV=1`. The authoritative `S6_KEEP_ENV=1` lives in the Dockerfile ENV (s6 stage0 reads it before any user code — with it unset, stage0 strips the container env and the Supervisor-injected `SUPERVISOR_TOKEN` never reaches run.sh). run.sh additionally resolves the token from the real env → legacy `HASSIO_TOKEN` → s6 `container_environment` envdirs, and re-exports it as `SUPERVISOR_TOKEN` (the `ha` CLI reads that literal name) plus `HA_TOKEN`.
2. Supervisor-API self-check: `SUPERVISOR_TOKEN` (injected by HA, never user-set) is re-exported as `HA_TOKEN`; two probe calls print OK/denied into the add-on log.
3. Sourcing `/homeassistant/.crushdata/env` (optional KEY=VALUE defaults; only allow-listed names, see `env_name_ok` in lib.sh; add a name there and in the README table when a new env var is introduced). The `local_ollama_url` option is resolved and exported as `LOCAL_OLLAMA_URL` right after.
4. Symlinks `/root/.config/crush` and `/root/.local/share/crush` into `/homeassistant/.crushdata/` for persistence (HA backups include `/homeassistant`).
5. Writes/patches `/homeassistant/.crushdata/CRUSH.md` — the agent-facing guardrails file crush ingests. Marker-based injection (`<!-- hasscrush-limits-start/end -->`) so user edits survive: never rewrite this file wholesale from run.sh; edit the `LIMITS_BODY` heredoc instead.
6. crushrc resolution: `crush_config_url` fetch (sanity-checked with grep for `provider|model add`) over a built-in fallback; the crushrc is a **bash script** that resolves `OLLAMA_API_KEY`/`MCP_TOKEN_<name>` from the environment run.sh exports.
7. Option overrides applied via sed: provider remap (third-party), model slots, reasoning effort, and the `mcp_servers` JSON merge (one option wires ALL MCP servers, tokens exported as `MCP_TOKEN_<name>` env vars, referenced not inlined).
8. Optional crush self-update (with rollback), then start the socat ingress gate (port 7681, accepts only the Supervisor ingress address `172.30.32.2`) and `exec ttyd` on loopback `127.0.0.1:7682` serving `tmux new-session -A -s crush`, with `--auth-header X-Hass-Source` kept as defense in depth. The launch argv is built by `ttyd_args`/`ingress_gate_args` in lib.sh (tested in `tests/ttyd_gate.bats`). The secret scan has one documented exception for that Supervisor address.

Key precedence everywhere: **real environment > env file (/homeassistant/.crushdata/env) > Options tab > central URL > persisted file**.

## Gotchas

- **Security rating is a Supervisor formula, not a guess** (`supervisor/apps/utils.py::rating_security`, scale 1-8, base 5): ingress +2, custom AppArmor profile +1, `hassio_role` manager -1 / admin -2, `host_network` -1, `host_pid` -2, privileged caps -1, docker/full access = 1. HASSCrush sits at 7: ingress, `apparmor.txt` and `hassio_role: manager` (from 1.0.49, so `ha core check/logs/stats` work; it was the default role, rating 8, in 1.0.45-1.0.48, where those commands returned 403). Admin-only endpoints stay denied by design and the CRUSH.md limits say so.
- **`init: false` in config.yaml is load-bearing.** s6-overlay must be pid 1; `init: true` re-parents it and the container dies with "can only run as pid 1".
- **No `full_access`/`docker_api` on purpose** — keeps HA's security rating at the hardened default. The CRUSH.md "Hard Limits" block tells the crush agent which denials are by design (hassio paths, `supervisor.*` websockets, docker) so it stops retrying them.
- **Never put a literal API key or private IP in any file.** CI's secret-scan step greps every tracked text file for known API-key prefixes and RFC 1918 addresses (10/8, 172.16/12, 192.168/16) and fails the build; the exact patterns live in `.github/workflows/ci.yml`. The default configs are deliberately free of real hosts/keys; secrets come from env/URLs. Test fixtures use RFC 5737 doc-range addresses (192.0.2.0/24) instead.
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