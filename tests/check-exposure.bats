#!/usr/bin/env bats
# check-exposure.sh against a fake curl: FAKE_CURL_MAP lines are
# "<host> <direct|forced> <http code>"; a missing line means no response (000).

setup() {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
url=${!#}; host=${url#https://}; host=${host%%/*}
mode=direct
for a in "$@"; do [[ $a == *:443:* ]] && mode=forced; done
code=$(awk -v h="$host" -v m="$mode" '$1 == h && $2 == m {print $3}' "$FAKE_CURL_MAP")
printf '%s' "${code:-000}"
[ "${code:-000}" != 000 ]
EOF
  chmod +x "$bin/curl"
  PATH="$bin:$PATH"
  export FAKE_CURL_MAP="$BATS_TEST_TMPDIR/map"
  script="$BATS_TEST_DIRNAME/../scripts/check-exposure.sh"
  internal="grafana argocd headlamp dex keycloak app-stage"
}

healthy_outside() {
  echo "app.bxota.com direct 200" > "$FAKE_CURL_MAP"
  for s in $internal; do echo "$s.bxota.com forced 404" >> "$FAKE_CURL_MAP"; done
}

healthy_inside() {
  echo "app.bxota.com direct 200" > "$FAKE_CURL_MAP"
  for s in $internal; do echo "$s.bxota.com direct 302" >> "$FAKE_CURL_MAP"; done
}

@test "outside passes when only the app answers" {
  healthy_outside
  run bash "$script" outside
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks passed"* ]]
}

@test "outside fails when an internal name answers from the internet" {
  healthy_outside
  echo "grafana.bxota.com direct 302" >> "$FAKE_CURL_MAP"
  run bash "$script" outside
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: grafana.bxota.com answered 302 from outside the tailnet"* ]]
}

@test "outside fails when the public IP serves an internal name" {
  healthy_outside
  sed -i 's/^dex.bxota.com forced 404$/dex.bxota.com forced 200/' "$FAKE_CURL_MAP"
  run bash "$script" outside
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: dex.bxota.com served on 15.224.195.86 with 200"* ]]
}

@test "outside fails when the app is down" {
  healthy_outside
  sed -i 's/^app.bxota.com direct 200$/app.bxota.com direct 503/' "$FAKE_CURL_MAP"
  run bash "$script" outside
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: app.bxota.com answered 503, expected 200"* ]]
}

@test "inside passes when every name answers" {
  healthy_inside
  run bash "$script" inside
  [ "$status" -eq 0 ]
}

@test "inside fails when an internal name has no answer or a 5xx" {
  healthy_inside
  sed -i -e '/^dex.bxota.com /d' -e 's/^keycloak.bxota.com direct 302$/keycloak.bxota.com direct 502/' "$FAKE_CURL_MAP"
  run bash "$script" inside
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: dex.bxota.com answered 000"* ]]
  [[ "$output" == *"FAIL: keycloak.bxota.com answered 502"* ]]
}

@test "usage error without a mode" {
  run bash "$script"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
