# HASSCharm — Home Assistant add-ons for Charm tools

Charm's terminal AI tools running inside Home Assistant, pointed at your own models and infrastructure.

## Add-ons

| Add-on | What it does |
|---|---|
| [`charm-crush/`](charm-crush/) | Charm Crush AI agent in the HA sidebar — GLM models via your own Ollama (local + cloud), persistent tmux sessions over ttyd ingress, optional shared mem0 memory layer |

## Install

1. **Settings → Add-ons → Add-on Store → ⋮ → Repositories**, add:
   `https://github.com/rainyvalley/HASSCharm`
2. Refresh the store; install the add-on.
3. Configure options in the add-on page, start it, open from the sidebar.

Full option and usage documentation in each add-on folder's README.

## License

MIT — see [LICENSE](LICENSE).