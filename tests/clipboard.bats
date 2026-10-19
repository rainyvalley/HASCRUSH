#!/usr/bin/env bats
# Copy/paste plumbing for the web terminal: tmux clipboard + mouse config, the
# ttyd client option, the client-side OSC 52 helpers and the terminal_mouse
# option wiring. Real tmux/ttyd/browsers cannot run here, so these pin the text.

load 'test_helper'
ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/charm-crush"
TMUXCONF="$ROOT/rootfs/root/.tmux.conf"
BAR="$ROOT/rootfs/touchbar.js"
RUN="$ROOT/rootfs/run.sh"

@test "tmux.conf forwards OSC 52 and honours the terminal_mouse switch" {
  grep -qx "set -g set-clipboard on" "$TMUXCONF"
  grep -q "terminal-features.*xterm\*:clipboard" "$TMUXCONF"
  grep -q "terminal-overrides.*Ms=" "$TMUXCONF"
  grep -q 'HASSCRUSH_MOUSE.*= off.*set -g mouse off' "$TMUXCONF"
  # the user override file still loads last
  [ "$(tail -n1 "$TMUXCONF" | cut -c1-17)" = "source-file -q /h" ]
}

@test "tmux.conf parses and mouse off applies when HASSCRUSH_MOUSE=off" {
  command -v tmux >/dev/null || skip "tmux not installed"
  sock="bats-$$"
  HASSCRUSH_MOUSE=off tmux -L "$sock" -f "$TMUXCONF" new-session -d 'sleep 20'
  m=$(tmux -L "$sock" show -gv mouse); c=$(tmux -L "$sock" show -gv set-clipboard)
  tmux -L "$sock" kill-server
  [ "$m" = off ] && [ "$c" = on ]
  HASSCRUSH_MOUSE=on tmux -L "$sock" -f "$TMUXCONF" new-session -d 'sleep 20'
  m=$(tmux -L "$sock" show -gv mouse)
  tmux -L "$sock" kill-server
  [ "$m" = on ]
}

@test "ttyd client lets Option+drag force selection on macOS" {
  mapfile -t a < <(ttyd_args 14 'background=#000' bash)
  [[ " ${a[*]} " == *" macOptionClickForcesSelection=true "* ]]
}

@test "touchbar.js registers OSC 52 and never inlines a closing script tag" {
  grep -q 'registerOscHandler(52' "$BAR"
  ! grep -q '</script' "$BAR"
  grep -q "action: 'copy'" "$BAR"
}

@test "touchbar_inject NOBAR flag adds bar:0 and the default prelude is unchanged" {
  setup_tmp
  printf '<html><body>x</body></html>' > "$TMP/src.html"
  printf 'window.__hassbar=1;' > "$TMP/bar.js"
  touchbar_inject "$TMP/src.html" "$TMP/bar.js" dark "$TMP/o1.html" 0 "" 1
  grep -q 'window.__HASSBAR={"theme":"dark","offset":0,"bar":0};' "$TMP/o1.html"
  touchbar_inject "$TMP/src.html" "$TMP/bar.js" dark "$TMP/o2.html" 0 1 1
  grep -q '"offset":0,"debug":1,"bar":0}' "$TMP/o2.html"
  touchbar_inject "$TMP/src.html" "$TMP/bar.js" dark "$TMP/o3.html"
  grep -q 'window.__HASSBAR={"theme":"dark","offset":0};' "$TMP/o3.html"
}

@test "terminal_mouse is wired: option, schema, translation, run.sh export" {
  grep -qx "  terminal_mouse: bool" "$ROOT/config.yaml"
  grep -q "^  terminal_mouse: true" "$ROOT/config.yaml"
  grep -qx "  terminal_mouse:" "$ROOT/translations/en.yaml"
  grep -q 'HASSCRUSH_MOUSE=off' "$RUN"
}

@test "run.sh injects the client page even when touch_bar is off" {
  [ "$(sed -n '/^_tb_index=/,/^# Only the Supervisor/p' "$RUN" | sed -n 2p)" = 'if [ -r /usr/local/share/ttyd-index.html ] && [ -r /usr/local/share/touchbar.js ]; then' ]
  grep -q '_tb_nobar=1' "$RUN"
}
