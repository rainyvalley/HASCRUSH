#!/usr/bin/env bats
# The ttyd launch line and the ingress gate in front of it. Real ttyd/socat
# cannot run in the unit suite, so these pin the argv that run.sh builds.

load 'test_helper'
RUN="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/charm-crush/rootfs/run.sh"
CFG="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/charm-crush/config.yaml"

@test "ingress constants: Supervisor ingress address, config.yaml ingress_port" {
  [ "$INGRESS_ADDR" = "172.30.32.2" ]
  grep -qx "ingress_port: $INGRESS_PORT" "$CFG"
  [ "$TTYD_BACKEND_PORT" != "$INGRESS_PORT" ]
}

@test "gate accepts only the ingress address and relays to loopback ttyd" {
  run ingress_gate_args
  [ "${lines[0]}" = "TCP4-LISTEN:7681,fork,reuseaddr,range=172.30.32.2/32" ]
  [ "${lines[1]}" = "TCP4:127.0.0.1:7682" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "ttyd listens on loopback only and keeps the header check" {
  mapfile -t a < <(ttyd_args 14 'background=#000' tmux new-session -A -s crush)
  s=" ${a[*]} "
  [[ "$s" == *" --interface 127.0.0.1 "* ]]
  [[ "$s" == *" --port 7682 "* ]]
  [[ "$s" == *" --auth-header X-Hass-Source "* ]]
  [[ "$s" == *" --writable "* ]]
  [[ "$s" != *"0.0.0.0"* ]]
  [[ "$s" != *" 7681 "* ]]
}

@test "ttyd argv ends with the shell command, theme and font passed through" {
  mapfile -t a < <(ttyd_args 16 'background=#fff' bash --login)
  n=${#a[@]}
  [ "${a[n-2]}" = bash ] && [ "${a[n-1]}" = "--login" ]
  [[ " ${a[*]} " == *" fontSize=16 "* ]]
  [[ " ${a[*]} " == *" theme=background=#fff "* ]]
}

@test "run.sh launches via the helpers: gate backgrounded, ttyd exec'd, no direct --port" {
  grep -q 'ingress_gate_args' "$RUN"
  grep -qE '^socat "\$\{_gate\[@\]\}" &' "$RUN"
  grep -qE '^exec ttyd "\$\{_ttyd\[@\]\}"' "$RUN"
  ! grep -qE 'ttyd --port' "$RUN"
}
