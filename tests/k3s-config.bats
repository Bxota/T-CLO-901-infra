#!/usr/bin/env bats
# The k3s config.yaml written by playbooks/server.yml must parse to plain
# strings: an unquoted list item ending with ':' (e.g. oidc-groups-prefix=oidc:)
# becomes a YAML map and k3s passes the apiserver a broken flag.

setup() {
  play="$BATS_TEST_DIRNAME/../playbooks/server.yml"
  rendered="$BATS_TEST_TMPDIR/config.yaml"
  yq '.[0].tasks[] | select(.name == "Write the k3s server configuration") | .["ansible.builtin.copy"].content' "$play" \
    | sed -e 's/{{ tailscale_ip.stdout | trim }}/100.89.166.31/' \
          -e 's#{{ oidc_issuer_url }}#https://dex.bxota.com#' > "$rendered"
}

@test "the rendered config has no Jinja left" {
  run grep -c '{{' "$rendered"
  [ "$output" = 0 ]
}

@test "every list item of the k3s config is a string" {
  run yq '[.[] | select(tag == "!!seq") | .[] | tag] | unique | join(",")' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = '!!str' ]
}

@test "the OIDC prefixes keep their trailing colon" {
  run yq '.kube-apiserver-arg[] | select(test("prefix"))' "$rendered"
  [ "$output" = "$(printf 'oidc-username-prefix=oidc:\noidc-groups-prefix=oidc:')" ]
}
