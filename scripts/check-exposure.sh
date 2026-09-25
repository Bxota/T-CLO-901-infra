#!/usr/bin/env bash
# Live check of the tailnet exposure model.
#   outside: run from a machine NOT on the tailnet (e.g. phone tethering)
#   inside:  run from a team laptop on the tailnet
# Every check is printed; the exit status is 1 if any failed.
set -uo pipefail
domain=${DOMAIN:-bxota.com}
public_ip=${PUBLIC_IP:-15.224.195.86}
internal=(grafana argocd headlamp dex keycloak app-stage)
failures=0

ok() { echo "ok:   $*"; }
ko() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# http_code HOST [curl args...]: the HTTP status, 000 when nothing answered
# (timeout, refused, TLS failure or untrusted certificate).
http_code() {
  local host=$1
  shift
  curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$@" "https://$host/" 2>/dev/null || true
}

outside() {
  local c h s
  c=$(http_code "app.$domain")
  if [ "$c" = 200 ]; then ok "app.$domain answers 200"; else ko "app.$domain answered $c, expected 200"; fi
  for s in "${internal[@]}"; do
    h="$s.$domain"
    c=$(http_code "$h")
    if [ "$c" = 000 ]; then ok "$h unreachable"; else ko "$h answered $c from outside the tailnet"; fi
    c=$(http_code "$h" -k --resolve "$h:443:$public_ip")
    case $c in
      000 | 404) ok "$h not served on $public_ip ($c)" ;;
      *) ko "$h served on $public_ip with $c" ;;
    esac
  done
}

inside() {
  local c h
  for h in "app.$domain" "${internal[@]/%/.$domain}"; do
    c=$(http_code "$h")
    case $c in
      000 | 5??) ko "$h answered $c" ;;
      *) ok "$h answers $c with a trusted certificate" ;;
    esac
  done
  if [ "${CHECK_KUBECTL:-0}" = 1 ]; then
    if kubectl get nodes >/dev/null; then ok "kubectl reaches the API over the tailnet"; else ko "kubectl get nodes failed"; fi
  fi
}

case ${1:-} in
  outside) outside ;;
  inside) inside ;;
  *) echo "usage: $0 outside|inside" >&2; exit 2 ;;
esac
if [ "$failures" -ne 0 ]; then echo "$failures check(s) failed" >&2; exit 1; fi
echo "all checks passed"
