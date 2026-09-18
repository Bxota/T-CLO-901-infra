# 2. Networking and TLS runbook

> Operational companion to the [networking and TLS design](../../../T-CLO-901/docs/superpowers/specs/2026-09-18-kube-design/02-networking-tls.md). It defines the public route contract and the commands for validating and promoting public certificates.

## Scope and prerequisites

This runbook consumes `public-gateway` in namespace `envoy-gateway-system` and its `https` listener. The verified, fixed public IP is `15.224.195.86`; public names use `sslip.io` and therefore need no managed DNS zone.

Before Argo CD reconciles the platform Kustomization, confirm that the AWS public security group permits inbound **TCP 80 and TCP 443** for this entry point. HTTP-01 validation reaches the public HTTP listener on port 80; HTTPS uses port 443. Do not change security groups from this runbook.

The k3s server must include `--kube-apiserver-arg=service-node-port-range=80-32767` in its install configuration (see the cluster initialization runbook). The default NodePort range excludes 80/443. The public Gateway owns these two NodePorts; keep Traefik and `servicelb` disabled and do not allocate either port to another Service.

Envoy's generated Service uses `externalTrafficPolicy: Cluster`: traffic arriving at `kube-1`'s NodePort can reach Envoy endpoints on the workers. `kube-1` is tainted and need not host an Envoy pod. Published URLs use standard HTTPS, for example `https://app.15.224.195.86.sslip.io/`.

## Clean-cluster GitOps bootstrap

The parent Argo CD Application owns `platform/networking` and lets the child Applications install their Helm releases. Do not apply these resources directly. The sync order is:

| Wave | Resources |
| --- | --- |
| `-3` | Controller namespaces |
| `-2` | Envoy Gateway Application, including Gateway API and Envoy Gateway CRDs |
| `-1` | cert-manager Application, including its CRDs and enabled Gateway API support |
| `0` | EnvoyProxy, GatewayClass, and both ClusterIssuers |
| `1` | Public Gateway and all four Certificates |

The section-3 parent must assess child Application health and wait for each controller release to finish before advancing its wave; merely creating a child Application does not mean its CRDs are installed. Gateway API CRDs must be present **before cert-manager starts**, because it discovers Gateway API support at startup.

Every first-party resource whose CRD is installed by a child Application (EnvoyProxy, GatewayClass, Gateway, both ClusterIssuers, and all Certificates) carries `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`. This allows the clean-cluster parent sync to get past its initial dry-run before the child apps install those CRDs; the wave and child-health gates still control actual reconciliation.

The Gateway and Certificates deliberately share wave `1`. The Gateway may initially observe missing TLS Secrets while cert-manager creates them. Its HTTP listener permits the solver routes to converge; waiting for Gateway health in an earlier wave would block the Certificates needed to make HTTPS healthy.

If cert-manager was started before the Gateway API CRDs existed, first let the Envoy Gateway Application finish syncing, then restart only the cert-manager controller so it discovers them:

```bash
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io --timeout=2m
kubectl -n cert-manager rollout restart deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=2m
```

## Inspect the public Gateway

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
PUBLIC_IP=15.224.195.86

kubectl get gatewayclass public-envoy
kubectl -n envoy-gateway-system get gateway public-gateway -o wide
kubectl -n envoy-gateway-system describe gateway public-gateway
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=public-gateway \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,POLICY:.spec.externalTrafficPolicy,PORTS:.spec.ports[*].port,NODEPORTS:.spec.ports[*].nodePort
kubectl -n argocd get applications.argoproj.io
```

The generated Service must show type `NodePort`, policy `Cluster`, service ports `80,443`, and NodePorts `80,443`. After certificate issuance converges, the Gateway must report `Programmed=True`. Its `https` listener terminates TLS and accepts routes from all namespaces, so application namespaces do **not** require a `ReferenceGrant`.

## Public route contract

Each owning section creates exactly one `gateway.networking.k8s.io/v1` `HTTPRoute` for its row after its Service is available. This runbook deliberately creates no routes: sections 3–6 own those manifests.

| Consumer | Hostname | Namespace | Service / port |
| --- | --- | --- | --- |
| Laravel | app.15.224.195.86.sslip.io | app | laravel:80 |
| Headlamp | headlamp.15.224.195.86.sslip.io | headlamp | headlamp:80 |
| Grafana | grafana.15.224.195.86.sslip.io | monitoring | kube-prometheus-stack-grafana:80 |
| Argo CD | argocd.15.224.195.86.sslip.io | argocd | argocd-server:80 |

Every route must use its row's hostname and this exact parent reference:

```yaml
parentRefs:
  - name: public-gateway
    namespace: envoy-gateway-system
    sectionName: https
```

The rest of each `HTTPRoute` selects that hostname and forwards to the Service and port shown above. Do not attach these user routes to the HTTP listener; cert-manager owns the temporary HTTP-01 solver routes there.

## Reconcile and inspect staging TLS

The root networking Kustomization initially selects `overlays/staging`, which binds the Certificates to `letsencrypt-staging`. Render locally for inspection, then let Argo CD reconcile the committed configuration and wait for the networking-related Applications to be `Synced` and `Healthy`:

```bash
kubectl kustomize platform/networking
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl get clusterissuer letsencrypt-staging letsencrypt-production
kubectl -n envoy-gateway-system get gateway,certificate
kubectl -n envoy-gateway-system wait --for=condition=Ready certificate \
  -l networking.kubequest2.io/certificate=public --timeout=10m
kubectl -n envoy-gateway-system describe gateway public-gateway
kubectl -n envoy-gateway-system describe certificate app-certificate
kubectl -n envoy-gateway-system get orders.acme.cert-manager.io,challenges.acme.cert-manager.io
kubectl get httproute -A
```

Each Certificate should become `Ready=True`; inspect `describe certificate`, then its associated Order and Challenge when it does not. Inspect the Gateway listener status for listener or reference errors, and inspect each HTTPRoute's `Accepted` and `ResolvedRefs` conditions after its owning section supplies it.

Validate staging connectivity only after the Laravel HTTPRoute exists. `--insecure` is **staging-only**, because Let's Encrypt staging certificates are intentionally untrusted:

```bash
PUBLIC_IP=15.224.195.86
curl --insecure -I --resolve "app.$PUBLIC_IP.sslip.io:443:$PUBLIC_IP" "https://app.$PUBLIC_IP.sslip.io/"
```

The expected Laravel response is `200`, `301`, or `302`. A staging Certificate may show an untrusted browser chain; that is expected for Let's Encrypt staging and must not be used as production acceptance.

## Production promotion

Promote only after staging validation succeeds and every relevant Argo CD Application is `Synced` and `Healthy`. Change only the root `platform/networking/kustomization.yaml` resource entry from `overlays/staging` to `overlays/production`, then commit the exact promotion intent:

```bash
git add platform/networking/kustomization.yaml
git commit -m "feat: promote public TLS certificates to letsencrypt production"
```

After Argo CD reconciles, repeat the Gateway, Certificate, Order, Challenge, and HTTPRoute inspections above and wait for all four Certificates to become `Ready=True`. Verify production with trusted TLS checks:

```bash
PUBLIC_IP=15.224.195.86
curl -I --resolve "app.$PUBLIC_IP.sslip.io:443:$PUBLIC_IP" "https://app.$PUBLIC_IP.sslip.io/"
openssl s_client -connect "$PUBLIC_IP:443" -servername "app.$PUBLIC_IP.sslip.io" \
  -verify_hostname "app.$PUBLIC_IP.sslip.io" -verify_return_error </dev/null
```

Production acceptance requires the expected HTTP status and OpenSSL output containing `Verify return code: 0 (ok)`; never use `--insecure` for this check.

## Rollback

If production issuance or public validation fails, revert only the same root Kustomization resource entry from `overlays/production` to `overlays/staging` and commit that inverse path change. Wait for Argo CD to return the networking Applications to `Synced` and `Healthy`, then repeat the staging checks.

Never delete ACME account keys and never churn Certificate resources to force another issuance. Preserve them so cert-manager can reconcile normally and so certificate-rate limits are not needlessly consumed.

## Troubleshooting

| Symptom | Checks and corrective action |
| --- | --- |
| NodePort cannot be reached | Confirm the public security group admits inbound TCP `80` and `443`, the k3s server uses `--kube-apiserver-arg=service-node-port-range=80-32767`, and Envoy's Service exposes those NodePorts with `externalTrafficPolicy: Cluster`. Confirm ready Envoy endpoints exist on workers; `kube-1` need not host Envoy. |
| Gateway is not Programmed | Run `kubectl -n envoy-gateway-system describe gateway public-gateway`; check GatewayClass/Envoy Gateway controller status and the HTTPS listener certificate references. |
| Certificate remains pending | Run `kubectl -n envoy-gateway-system describe certificate <name>`, then inspect `orders.acme.cert-manager.io` and `challenges.acme.cert-manager.io` in that namespace. Confirm the HTTP listener and public port `80` remain reachable for HTTP-01. If cert-manager started before Gateway API CRDs were installed, use the controller restart procedure above. |
| HTTPRoute is not accepted | Run `kubectl -n <namespace> describe httproute <name>`; verify the exact HTTPS parent reference, hostname, Service name, port, and `Accepted`/`ResolvedRefs` conditions. No cross-namespace `ReferenceGrant` is needed. |
| Browser warns after staging issuance | Expected: staging's chain is untrusted. Promote only after staging behavior is otherwise validated, then require `Verify return code: 0 (ok)` from the production OpenSSL check. |
| Argo state does not converge | Check `kubectl -n argocd get applications.argoproj.io`, application events, and the rendered `platform/networking` Kustomization before changing certificates or account keys. |
