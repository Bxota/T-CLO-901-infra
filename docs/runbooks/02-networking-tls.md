# 2. Networking and TLS runbook

> Operational companion to the [networking and TLS design](../../../T-CLO-901/docs/superpowers/specs/2026-09-18-kube-design/02-networking-tls.md) and the [tailnet private exposure design](../../../T-CLO-901/docs/superpowers/specs/2026-09-25-tailnet-private-exposure-design.md). It defines the two entry points, the DNS records, certificate issuance, and the exposure checks.

## Exposure model

Only the production app is public. Every other tool is reachable only from the team's tailnet.

```
Internet ──TCP 80/443──► 15.224.195.86 (kube-1, eth0)
                           └─ NodePort 80/443 (nodeport-addresses = primary)
                               └─ public-gateway ─► app.bxota.com ─► namespace app

Tailnet ──WireGuard──► 100.89.166.31 (kube-1, tailscale0)
                           └─ Service envoy-internal, externalIPs [100.89.166.31]:443
                               └─ internal-gateway ─► grafana, argocd, headlamp,
                                                      dex, keycloak, app-stage
```

| Gateway | Reached on | Listeners | Certificate | Routes admitted from |
| --- | --- | --- | --- | --- |
| `public-gateway` | `15.224.195.86` NodePort 80/443 | `http` (HTTP-01 + redirect), `https` | `app-tls` (`app.bxota.com`, HTTP-01) | `https`: namespace `app`; `http`: `app`, `envoy-gateway-system` |
| `internal-gateway` | `100.89.166.31:443` (Service `envoy-internal`, externalIP) | `https` | `internal-tls` (six names, DNS-01) | `monitoring`, `headlamp`, `argocd`, `identity`, `app-stage` |

Isolation is at the network layer: traffic to the public IP only reaches `public-gateway`, which has no route and no certificate for internal names; traffic to the Tailscale IP only reaches `envoy-internal`, because kube-proxy on `kube-1` runs with `nodeport-addresses=primary` (NodePorts answer on the VPC address only). Dex and Keycloak are the second layer.

The AWS security group admits inbound **TCP 80 and 443** only. Tailscale is WireGuard over outbound UDP (DERP relays as fallback) and needs no inbound rule. Do not change security groups from this runbook.

The k3s server keeps `service-node-port-range: 80-32767` (the default range excludes 80/443) and Traefik and `servicelb` stay disabled; all flags live in `/etc/rancher/k3s/config.yaml`, written by `playbooks/server.yml`. Both Envoy Services use `externalTrafficPolicy: Cluster`: `kube-1` is tainted and never hosts Envoy, so traffic arriving on it must be forwarded to Envoy pods on the workers.

## DNS records

Records live in the IONOS console for `bxota.com`. They are created by hand; the website's own records are never touched. No wildcard record: it would capture every undefined subdomain of the website's domain.

| Host | Type | Value |
| --- | --- | --- |
| `app` | A | `15.224.195.86` |
| `grafana`, `argocd`, `headlamp`, `dex`, `keycloak`, `app-stage` | A | `100.89.166.31` (kube-1's Tailscale IP) |

The internal records are public but only reveal a `100.64.0.0/10` address, unreachable outside the tailnet. If `kube-1`'s Tailscale IP changes, see runbook 01, "Tailscale IP after a rebuild".

## Clean-cluster GitOps bootstrap

The parent Argo CD Application owns `platform/networking`. Do not apply these resources directly. The sync order is:

| Wave | Resources |
| --- | --- |
| `-3` | Controller namespaces |
| `-2` | Envoy Gateway Application, including Gateway API and Envoy Gateway CRDs |
| `-1` | cert-manager Application (CRDs, Gateway API support, public recursive nameservers for DNS-01); SealedSecret `cert-manager/ionos-secret` |
| `0` | IONOS DNS-01 webhook Application; both EnvoyProxies and GatewayClasses; both ClusterIssuers |
| `1` | Both Gateways, both Certificates, the HTTP→HTTPS redirect route, ConfigMap `kube-system/coredns-custom` |
| `2`–`4` | Tool routes on `internal-gateway` (Keycloak 1, Dex 2, Grafana/Headlamp/Argo CD 4) |

**Every route on a Gateway must be in the same or a later wave than that Gateway.** Argo CD waits for each wave to be healthy, and a route whose Gateway does not exist yet never is: the whole sync stays `Progressing` (this happened once with the Argo CD route). `scripts/check-exposure-config.sh` fails the lint job on such a route.

Every first-party resource whose CRD is installed by a child Application carries `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, so the clean-cluster parent sync gets past its initial dry-run.

The Gateways and Certificates share wave `1` on purpose: a Gateway may observe a missing TLS Secret while cert-manager creates it. `envoy-internal` only appears once `internal-tls` exists; before that, `internal-gateway` is not Programmed.

If cert-manager was started before the Gateway API CRDs existed, let the Envoy Gateway Application finish syncing, then restart only the cert-manager controller:

```bash
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io --timeout=2m
kubectl -n cert-manager rollout restart deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=2m
```

## Certificates

Both ClusterIssuers (`letsencrypt-staging`, `letsencrypt-production`) carry two solvers:

- **HTTP-01** on `public-gateway`'s `http` listener: the default, used by `app.bxota.com`.
- **DNS-01** through `cert-manager-webhook-ionos` (chart and image `1.3.1`, group `acme.fabmade.de`, solver `ionos`), selected by `dnsNames` for the six internal names: Let's Encrypt cannot reach a `100.x` address, so ownership is proven with a TXT record. The webhook reads `IONOS_PUBLIC_PREFIX` and `IONOS_SECRET` from the SealedSecret `cert-manager/ionos-secret`.

cert-manager asks `1.1.1.1` and `8.8.8.8` directly for DNS-01 propagation checks (`--dns01-recursive-nameservers-only`), not the VPC resolver.

Base Certificates reference `letsencrypt-staging`; the production overlay patches every Certificate labelled `networking.kubequest2.io/certificate: public` (both of them) to `letsencrypt-production`. A new certificate is added without the label first, proven on staging, then labelled.

Inspect:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n envoy-gateway-system get gateway,certificate
kubectl -n envoy-gateway-system get svc envoy-internal -o jsonpath='{.spec.type} {.spec.externalIPs} {.spec.externalTrafficPolicy}{"\n"}'
kubectl -n envoy-gateway-system get orders.acme.cert-manager.io,challenges.acme.cert-manager.io
kubectl get httproute -A
```

Expected: both Gateways `PROGRAMMED True`, both Certificates `READY True`, `envoy-internal` = `ClusterIP ["100.89.166.31"] Cluster`, and only `*.bxota.com` hostnames in the routes.

### Rotate the IONOS API key

IONOS API keys cannot be scoped to one zone: the key can edit every record of `bxota.com`, including the website's. Keep it only as a SealedSecret. To rotate: create a new key at `developer.hosting.ionos.com`, seal it (no `kubectl` needed; the key is typed at a prompt and only the ciphertext reaches disk), commit, release an infra tag, then delete the old key:

```bash
read -rp 'IONOS prefix: ' p; read -rsp 'IONOS secret: ' s; echo     # paste this line alone
cat <<EOF | kubeseal --cert sealed-secrets/pub-cert.pem --format yaml > platform/networking/22-ionos-credentials.sealedsecret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ionos-secret
  namespace: cert-manager
type: Opaque
stringData:
  IONOS_PUBLIC_PREFIX: '$p'
  IONOS_SECRET: '$s'
EOF
unset p s
yq -i '.metadata.annotations["argocd.argoproj.io/sync-wave"] = "-1" | .metadata.annotations["argocd.argoproj.io/sync-options"] = "SkipDryRunOnMissingResource=true"' platform/networking/22-ionos-credentials.sealedsecret.yaml
```

Paste the `read` line on its own: when several lines are pasted at once, `read` takes the next pasted line as its answer.

## Route contract

| Consumer | Hostname | Namespace | Service / port | Gateway |
| --- | --- | --- | --- | --- |
| Laravel (prod) | app.bxota.com | app | laravel:80 | `public-gateway` |
| Laravel (stage) | app-stage.bxota.com | app-stage | laravel:80 | `internal-gateway` |
| Grafana | grafana.bxota.com | monitoring | kube-prometheus-stack-grafana:80 | `internal-gateway` |
| Headlamp | headlamp.bxota.com | headlamp | headlamp:80 | `internal-gateway` |
| Argo CD | argocd.bxota.com | argocd | argocd-server:80 | `internal-gateway` |
| Dex | dex.bxota.com | identity | dex:5556 | `internal-gateway` |
| Keycloak | keycloak.bxota.com | identity | keycloak-keycloakx-http:80 | `internal-gateway` |

Every route uses its gateway's `https` listener:

```yaml
parentRefs:
  - name: internal-gateway        # or public-gateway for app.bxota.com only
    namespace: envoy-gateway-system
    sectionName: https
```

`public-gateway` refuses routes from any namespace but `app` on `https`, so an internal tool cannot be exposed by mistake. Do not attach user routes to the `http` listener: cert-manager owns the HTTP-01 solver routes there, next to `https-redirect`.

## Pods and the API server reaching Dex and Keycloak

Pods are not on the tailnet, yet Dex calls Keycloak, and Grafana, Argo CD and Headlamp call Dex server-side. The k3s `coredns-custom` ConfigMap (`platform/networking/50-coredns-internal.yaml`) rewrites exactly `dex.bxota.com` and `keycloak.bxota.com` to `envoy-internal.envoy-gateway-system.svc.cluster.local`, so pods use the same hostname and certificate as browsers. The API server on `kube-1` resolves `dex.bxota.com` to the local Tailscale address, and kube-proxy's externalIP rule sends it to `envoy-internal`.

```bash
kubectl run dns-probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'nslookup dex.bxota.com; curl -s -o /dev/null -w "%{http_code}\n" https://dex.bxota.com/healthz'
curl -s -o /dev/null -w '%{http_code}\n' https://dex.bxota.com/healthz      # on kube-1
```

Expected: the `envoy-internal` ClusterIP under the name `dex.bxota.com`, then `200`, twice.

## Exposure checks

Static, in the infra lint job: `scripts/check-exposure-config.sh --final` (internal hosts only on `internal-gateway`, no NodePort on it, the single Tailscale IP, sync-wave order, CoreDNS rewrite, app environments, identity URLs, no sslip.io, public gateway restricted to the app).

Live, `scripts/check-exposure.sh`:

```bash
bash scripts/check-exposure.sh inside     # from a laptop on the tailnet
bash scripts/check-exposure.sh outside    # from a machine that is NOT on the tailnet
curl -sI http://app.bxota.com/ | head -1  # HTTP/1.1 301 Moved Permanently
```

`inside`: every name answers with a trusted certificate. `outside`: `app.bxota.com` answers `200`, each internal name is unreachable, and forcing it to `15.224.195.86` gives `404` or no answer.

**"Outside" means every Tailscale client of the machine is down.** On Windows with WSL, `sudo tailscale down` in WSL is not enough: WSL traffic leaves through Windows, whose own Tailscale client keeps it on the tailnet. Disconnect the Windows client too (tray icon → Disconnect), or use a phone on mobile data with Tailscale off.

## Troubleshooting

| Symptom | Checks and corrective action |
| --- | --- |
| Platform sync stays `Progressing` on a route | The route is in an earlier sync wave than its Gateway. Give it a later wave; `check-exposure-config.sh` reports it. |
| `internal-certificate` not Ready | `kubectl -n envoy-gateway-system describe challenge`; webhook pod logs (`kubectl -n cert-manager logs deploy/cert-manager-webhook-ionos`); IONOS key valid (`curl -H "X-API-Key: <prefix>.<secret>" https://api.hosting.ionos.com/dns/v1/zones` → 200 with `bxota.com`); `nslookup -type=TXT _acme-challenge.grafana.bxota.com 1.1.1.1` during the challenge. |
| `envoy-internal` missing, `internal-gateway` not Programmed | Expected until `internal-tls` exists; then check the Envoy Gateway controller logs. |
| Internal names time out on a tailnet laptop | `tailscale status` lists kube-1; `nslookup grafana.bxota.com` returns `100.89.166.31`. If it returns nothing, the local resolver drops `100.x` answers (DNS-rebinding protection): in the Tailscale admin console, DNS → add global nameserver `1.1.1.1` and enable "Override local DNS". |
| Internal names time out for everyone | `envoy-internal`'s externalIP equals `tailscale ip -4` on kube-1; Envoy internal pods Running; `kubectl -n kube-system get cm coredns-custom` present. |
| NodePort cannot be reached from the internet | Security group admits TCP 80/443; `service-node-port-range: 80-32767` in `/etc/rancher/k3s/config.yaml`; public Envoy Service exposes NodePorts 80/443 with `externalTrafficPolicy: Cluster`. |
| `outside` check reports internal names answering | Confirm the machine is really off the tailnet (see "Exposure checks"); the forced-IP lines are the ones that test the internet path. |
| A script fails with `$'\r': command not found` | A Windows checkout added CRLF. `.gitattributes` keeps `*.sh`/`*.bats` in LF; re-checkout, or run `bash <(tr -d '\r' < script)`. |
