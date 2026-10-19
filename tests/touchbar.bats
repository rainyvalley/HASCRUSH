#!/usr/bin/env bats
# The touch bar: a custom ttyd index page (built from the build-time-extracted
# embedded client page) with the bar script spliced in before </body>, handed
# to ttyd via its --index option. Real ttyd cannot run in the unit suite, so
# these pin touchbar_inject's splicing rules and the ttyd --index passthrough.

load 'test_helper'

@test "touchbar_inject splices the prelude and bar before </body>" {
  setup_tmp
  printf '<html><body>x</body></html>' > "$TMP/src.html"
  printf 'window.__hassbar=1;' > "$TMP/bar.js"
  touchbar_inject "$TMP/src.html" "$TMP/bar.js" dark "$TMP/out.html"
  grep -q '<script>window.__HASSBAR={"theme":"dark"};</script>' "$TMP/out.html"
  grep -q '<script>window.__hassbar=1;</script>' "$TMP/out.html"
  h=$(grep -bo 'window\.__HASSBAR' "$TMP/out.html" | head -1 | cut -d: -f1)
  b=$(grep -bo '</body>' "$TMP/out.html" | head -1 | cut -d: -f1)
  [ "$h" -lt "$b" ]
}

@test "touchbar_inject falls back to </html>, then appends" {
  setup_tmp
  printf '<html><body>x</html>' > "$TMP/no_body.html"
  printf 'window.__hassbar=1;' > "$TMP/bar.js"
  touchbar_inject "$TMP/no_body.html" "$TMP/bar.js" dark "$TMP/out1.html"
  b=$(grep -bo '</html>' "$TMP/out1.html" | head -1 | cut -d: -f1)
  h=$(grep -bo 'window\.__HASSBAR' "$TMP/out1.html" | head -1 | cut -d: -f1)
  [ "$h" -lt "$b" ]

  printf '<html>x' > "$TMP/no_close.html"
  touchbar_inject "$TMP/no_close.html" "$TMP/bar.js" dark "$TMP/out2.html"
  t=$(wc -c < "$TMP/out2.html")
  [ "$((t))" -gt "$(wc -c < "$TMP/no_close.html")" ]
}

@test "touchbar_inject injects exactly once and refuses an already-marked page" {
  setup_tmp
  printf '<html><body>x</body></html>' > "$TMP/src.html"
  printf 'window.__hassbar=1;' > "$TMP/bar.js"
  touchbar_inject "$TMP/src.html" "$TMP/bar.js" dark "$TMP/out.html"
  [ "$(grep -c 'window\.__HASSBAR={"theme"' "$TMP/out.html")" -eq 1 ]

  ! touchbar_inject "$TMP/out.html" "$TMP/bar.js" dark "$TMP/out2.html"
  [ ! -e "$TMP/out2.html" ]
}

@test "touchbar_inject coerces an invalid theme to dark and fails closed on missing inputs" {
  setup_tmp
  printf '<html><body>x</body></html>' > "$TMP/src.html"
  printf 'window.__hassbar=1;' > "$TMP/bar.js"
  touchbar_inject "$TMP/src.html" "$TMP/bar.js" "polka" "$TMP/out.html"
  grep -q 'window.__HASSBAR={"theme":"dark"}' "$TMP/out.html"

  ! touchbar_inject "$TMP/absent.html" "$TMP/bar.js" dark "$TMP/out2.html" 2>/dev/null
  ! touchbar_inject "$TMP/src.html" "$TMP/absent.js" dark "$TMP/out3.html" 2>/dev/null
 [ ! -e "$TMP/out2.html" ]
}

@test "touchbar_inject preserves byte-identity outside the splice" {
  setup_tmp
  page='<html><head><style>a{}b{}</style></head><body><script>var x=1;</script></body></html>'
  printf '%s' "$page" > "$TMP/src.html"
  printf 'window.__hassbar=1;' > "$TMP/bar.js"
  touchbar_inject "$TMP/src.html" "$TMP/bar.js" light "$TMP/out.html"
  before=${page%%'</body>'*}
  after=${page#*'</body>'}
  head=$(head -c "${#before}" "$TMP/out.html")
  [ "$head" = "$before" ]
  # the </body>...</html> tail is byte-identical; the normalised final LF is
  # appended by the injector and stripped again by command substitution
  tail=$(tail -c "$(( ${#after} + 1 ))" "$TMP/out.html")
  [ "$tail" = "$after" ]
}