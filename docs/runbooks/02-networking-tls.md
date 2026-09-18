# 2. Networking and TLS runbook

> Operational companion to the [networking and TLS design](../../../T-CLO-901/docs/superpowers/specs/2026-09-18-kube-design/02-networking-tls.md). It defines the public route contract and the commands for validating and promoting public certificates.

## Scope and prerequisites

This runbook consumes `public-gateway` in namespace `envoy-gateway-system` and its `https` listener. The verified, fixed public IP is `15.224.195.86`; public names use `sslip.io` and therefore need no managed DNS zone.

Before applying the platform Kustomization, confirm that Envoy Gateway and cert-manager are installed by their Argo CD Applications, that the Gateway API CRDs are present, and that the public security group permits **only TCP 30080 and TCP 30443** for this entry point. Do not change security groups from this runbook.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
PUBLIC_IP=15.224.195.86

kubectl get gatewayclass public-envoy
kubectl -n envoy-gateway-system get gateway public-gateway -o wide
kubectl -n envoy-gateway-system describe gateway public-gateway
kubectl -n argocd get applications.argoproj.io
```

The Gateway must report `Programmed=True`. Its `https` listener terminates TLS and accepts routes from all namespaces, so application namespaces do **not** require a `ReferenceGrant`.

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

## Apply and inspect staging TLS

The root networking Kustomization initially selects `overlays/staging`, which binds the Certificates to `letsencrypt-staging`.

```bash
kustomize build platform/networking | kubectl apply --server-side -f -
kubectl -n argocd get applications.argoproj.io
kubectl -n envoy-gateway-system get gateway,certificate
kubectl -n envoy-gateway-system get orders.acme.cert-manager.io,challenges.acme.cert-manager.io
kubectl get httproute -A
```

For GitOps-managed environments, let Argo CD perform the apply and wait for its networking-related Applications to be `Synced` and `Healthy` instead of applying by hand:

```bash
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n envoy-gateway-system describe gateway public-gateway
kubectl -n envoy-gateway-system describe certificate app-certificate
kubectl -n envoy-gateway-system get orders.acme.cert-manager.io,challenges.acme.cert-manager.io
kubectl get httproute -A
```

Each Certificate should become `Ready=True`; inspect `describe certificate`, then its associated Order and Challenge when it does not. Inspect the Gateway listener status for listener or reference errors, and inspect each HTTPRoute's `Accepted` and `ResolvedRefs` conditions after its owning section supplies it.

Validate the Laravel route only after the Laravel HTTPRoute exists:

```bash
PUBLIC_IP=15.224.195.86
curl -I --resolve "app.$PUBLIC_IP.sslip.io:30443:$PUBLIC_IP" "https://app.$PUBLIC_IP.sslip.io:30443/"
openssl s_client -connect "$PUBLIC_IP:30443" -servername "app.$PUBLIC_IP.sslip.io" -verify_return_error </dev/null
```

The expected Laravel response is `200`, `301`, or `302`. A staging Certificate may show an untrusted browser chain; that is expected for Let's Encrypt staging and must not be used as production acceptance.

## Production promotion

Promote only after staging validation succeeds and every relevant Argo CD Application is `Synced` and `Healthy`. Change only the root `platform/networking/kustomization.yaml` resource entry from `overlays/staging` to `overlays/production`, then commit the exact promotion intent:

```bash
git add platform/networking/kustomization.yaml
git commit -m "feat: promote public TLS certificates to letsencrypt production"
```

After Argo CD reconciles, repeat the Gateway, Certificate, Order, Challenge, HTTPRoute, curl, and OpenSSL inspections above. Production validation requires the OpenSSL output to contain `Verify return code: 0 (ok)`.

## Rollback

If production issuance or public validation fails, revert only the same root Kustomization resource entry from `overlays/production` to `overlays/staging` and commit that inverse path change. Wait for Argo CD to return the networking Applications to `Synced` and `Healthy`, then repeat the staging checks.

Never delete ACME account keys and never churn Certificate resources to force another issuance. Preserve them so cert-manager can reconcile normally and so certificate-rate limits are not needlessly consumed.

## Troubleshooting

| Symptom | Checks and corrective action |
| --- | --- |
| NodePort cannot be reached | Confirm the public security group admits TCP `30080` and `30443`, then confirm Envoy's Service exposes those NodePorts. No other public port is required for this path. |
| Gateway is not Programmed | Run `kubectl -n envoy-gateway-system describe gateway public-gateway`; check GatewayClass/Envoy Gateway controller status and the HTTPS listener certificate references. |
| Certificate remains pending | Run `kubectl -n envoy-gateway-system describe certificate <name>`, then inspect `orders.acme.cert-manager.io` and `challenges.acme.cert-manager.io` in that namespace. Confirm the HTTP listener and port `30080` remain reachable for HTTP-01. |
| HTTPRoute is not accepted | Run `kubectl -n <namespace> describe httproute <name>`; verify the exact HTTPS parent reference, hostname, Service name, port, and `Accepted`/`ResolvedRefs` conditions. No cross-namespace `ReferenceGrant` is needed. |
| Browser warns after staging issuance | Expected: staging's chain is untrusted. Promote only after staging behavior is otherwise validated, then require `Verify return code: 0 (ok)` from the production OpenSSL check. |
| Argo state does not converge | Check `kubectl -n argocd get applications.argoproj.io`, application events, and the rendered `platform/networking` Kustomization before changing certificates or account keys. |
