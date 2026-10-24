# HASSCrush

**Charm [Crush](https://github.com/charmbracelet/crush) — the terminal-first AI agent — in your Home Assistant sidebar.**

Full documentation: **[DOCS.md](DOCS.md)** (also available as the add-on's Documentation tab) and
the repo root [README.md](../README.md).

## What's in this folder

- `config.yaml` — add-on definition (options + schema)
- `Dockerfile`, `rootfs/run.sh` — build + startup
- `rootfs/lib.sh` — helper functions used by `run.sh` (unit-tested)
- `rootfs/touchbar.js` — the on-screen key bar and copy/paste helpers for the web terminal
- `DOCS.md` — full usage documentation
- `icon.png` / `logo.png` — icons
- `translations/en.yaml` — options UI labels
