#!/usr/bin/env bash
# Static check of the tailnet exposure model (coordination repo spec
# 2026-09-25-tailnet-private-exposure-design.md). Always: internal hostnames
# are served only by internal-gateway, which never gets a NodePort; app-stage
# is internal and app prod is public. With --final: the sslip.io transition is
# over and the public gateway serves app.bxota.com only.
set -euo pipefail
cd "$(dirname "$0")/.."
final=false
[ "${1:-}" = "--final" ] && final=true

internal_hosts="app-stage.bxota.com argocd.bxota.com dex.bxota.com grafana.bxota.com headlamp.bxota.com keycloak.bxota.com"
tailnet_ip='^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$'

build=$(mktemp)
trap 'rm -f "$build"' EXIT
${KUSTOMIZE:-kustomize} build platform > "$build"

fail() { echo "FAIL: $*" >&2; exit 1; }
q() { yq -N "$1" "$build"; }
sorted() { tr ' ,' '\n\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//'; }
is_internal() { case " $internal_hosts " in *" $1 "*) return 0 ;; esac; return 1; }

# Internal gateway: one HTTPS listener, internal-tls only, never a NodePort.
gw='select(.kind == "Gateway" and .metadata.name == "internal-gateway")'
[ "$(q "$gw | .metadata.name")" = internal-gateway ] || fail "Gateway internal-gateway not found"
{ [ "$(q "$gw | .spec.listeners | length")" = 1 ] && [ "$(q "$gw | .spec.listeners[0].protocol")" = HTTPS ] \
  && [ "$(q "$gw | .spec.listeners[0].port")" = 443 ]; } || fail "internal-gateway must have exactly one HTTPS:443 listener"
[ "$(q "$gw | .spec.listeners[0].tls.certificateRefs | map(.name) | join(\",\")")" = internal-tls ] \
  || fail "internal-gateway must reference internal-tls only"

proxy='select(.kind == "EnvoyProxy" and .metadata.name == "internal-proxy") | .spec.provider.kubernetes.envoyService'
[ "$(q "$proxy | .type")" = ClusterIP ] || fail "internal-proxy Service must be ClusterIP"
[ "$(q "$proxy | .name")" = envoy-internal ] || fail "internal-proxy Service must be named envoy-internal"
[ "$(q "$proxy | .externalTrafficPolicy")" = Cluster ] \
  || fail "internal-proxy needs externalTrafficPolicy Cluster (Envoy never runs on kube-1)"
ips=$(q "$proxy | (.patch.value.spec.externalIPs // []) | join(\" \")")
{ [ "$(wc -w <<<"$ips")" -eq 1 ] && [[ $ips =~ $tailnet_ip ]]; } \
  || fail "internal-proxy externalIPs must be kube-1's single Tailscale IP, got '$ips'"

q 'select(.kind == "Gateway" and .metadata.name == "public-gateway") | .spec.listeners[] | (.tls.certificateRefs // [])[] | .name' \
  | grep -qx internal-tls && fail "public-gateway must not serve internal-tls"

cert='select(.kind == "Certificate" and .metadata.name == "internal-certificate")'
[ "$(q "$cert | .spec.secretName")" = internal-tls ] || fail "internal-certificate must write internal-tls"
[ "$(q "$cert | .spec.dnsNames | join(\" \")" | sorted)" = "$internal_hosts" ] \
  || fail "internal-certificate dnsNames must be exactly: $internal_hosts"

# Every route: internal hosts through internal-gateway only, and nothing else on it.
while read -r route host parents; do
  [ -n "$route" ] || continue
  if is_internal "$host"; then
    [ "$parents" = internal-gateway ] || fail "$route serves internal host $host through '$parents'"
  elif [[ ",$parents," == *,internal-gateway,* ]]; then
    fail "$route attaches $host to internal-gateway, which serves internal hosts only"
  fi
done < <(q 'select(.kind == "HTTPRoute") | (.metadata.namespace + "/" + .metadata.name) as $r | (.spec.parentRefs | map(.name) | unique | join(",")) as $p | (.spec.hostnames // [])[] | $r + " " + . + " " + $p')

# Pods reach Dex and Keycloak through the internal Envoy Service.
cm=$(q 'select(.kind == "ConfigMap" and .metadata.name == "coredns-custom" and .metadata.namespace == "kube-system") | .data["bxota-internal.override"]')
for h in dex.bxota.com keycloak.bxota.com; do
  grep -q "rewrite name exact $h envoy-internal.envoy-gateway-system.svc.cluster.local" <<<"$cm" \
    || fail "CoreDNS does not rewrite $h to envoy-internal"
done

# The app chart's routes come from the Argo CD Applications' values.
v='.spec.source.helm.valuesObject'
stage=platform/apps/app-stage.yaml
prod=platform/apps/app-prod.yaml
[ "$(yq "$v.route.host" "$stage")" = app-stage.bxota.com ] || fail "app-stage host must be app-stage.bxota.com"
[ "$(yq "$v.route.gateway.name" "$stage")" = internal-gateway ] || fail "app-stage must attach to internal-gateway"
[ "$(yq "$v.env.APP_URL" "$stage")" = https://app-stage.bxota.com ] || fail "app-stage APP_URL must be https://app-stage.bxota.com"
[ "$(yq "$v.route.host" "$prod")" = app.bxota.com ] || fail "app-prod host must be app.bxota.com"
[ "$(yq "$v.route.gateway.name // \"public-gateway\"" "$prod")" = public-gateway ] || fail "app-prod must stay on public-gateway"
[ "$(yq "$v.env.APP_URL" "$prod")" = https://app.bxota.com ] || fail "app-prod APP_URL must be https://app.bxota.com"

if $final; then
  if grep -q 'sslip\.io' "$build" platform/apps/*.yaml; then fail "sslip.io hostnames remain under platform/"; fi
  pub='select(.kind == "Gateway" and .metadata.name == "public-gateway") | .spec.listeners[]'
  [ "$(q "$pub | select(.name == \"https\") | .tls.certificateRefs | map(.name) | join(\",\")")" = app-tls ] \
    || fail "public-gateway https must serve app-tls only"
  [ "$(q "$pub | select(.name == \"https\") | .allowedRoutes.namespaces.selector.matchExpressions[0].values | join(\",\")")" = app ] \
    || fail "public-gateway https must admit routes from namespace app only"
  [ "$(q "$pub | select(.name == \"http\") | .allowedRoutes.namespaces.selector.matchExpressions[0].values | sort | join(\",\")")" = "app,envoy-gateway-system" ] \
    || fail "public-gateway http must admit routes from app and envoy-gateway-system only"
  [ "$(q 'select(.kind == "HTTPRoute") | select(.spec.parentRefs[].name == "public-gateway") | .metadata.namespace + "/" + .metadata.name' | sort -u | tr '\n' ' ')" = "envoy-gateway-system/https-redirect " ] \
    || fail "the only platform route on public-gateway must be envoy-gateway-system/https-redirect"
  [ "$(q 'select(.kind == "Certificate" and .metadata.name == "app-certificate") | .spec.dnsNames | join(" ")')" = app.bxota.com ] \
    || fail "app-certificate must cover app.bxota.com only"
fi
echo "ok: exposure model"
