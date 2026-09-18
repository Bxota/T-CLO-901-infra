# 5. Observability runbook

> Operational companion to the [observability design](../../../T-CLO-901/docs/superpowers/specs/2026-09-18-kube-design/05-observability.md).

## Scope and prerequisites

Consumes `public-gateway` in `envoy-gateway-system` (spec 2, already deployed) and its `https` listener. Every node needs `nfs-utils` installed (spec 1, Task 1 of this plan) before the shared EFS filesystem `fs-04525e4ba350e77a0.efs.eu-west-3.amazonaws.com` can be mounted.

## Sync order

| Wave | Resources |
| --- | --- |
| `2` | `monitoring`/`headlamp` namespaces, the `efs-bootstrap-loki` Job, Loki's static `PersistentVolume` |
| `3` | `kube-prometheus-stack`, `loki`, `alloy`, `headlamp` Applications |
| `4` | `grafana` and `headlamp` `HTTPRoute`s |

Wave `3` is one flat group: none of the four Applications depend on each other, only on wave `2`'s namespaces/storage. Wave `4` waits for wave `3`'s child Applications to be Healthy, so both backend Services exist before their routes are created.

## Shared EFS convention

The shared EFS filesystem is mounted directly with Kubernetes' built-in `nfs` volume type — no CSI driver, no extra AWS IAM permissions. Each consumer gets one subdirectory, created once by a small bootstrap `Job` that mounts the export root (`path: /`) and `mkdir -p`s its subdirectory before any real workload tries to mount it. Loki owns `/loki`. The application section (6) reuses this exact pattern for MySQL's `/mysql-data` and `/mysql-backups`; do not point a new consumer at a name already listed here.

## Inspect the stack

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n argocd get applications.argoproj.io
kubectl -n monitoring get pods
kubectl -n monitoring get pvc storage-loki-0 -o wide
kubectl -n monitoring get pv loki-data -o wide
kubectl -n headlamp get pods
kubectl get node -l node-role.kubernetes.io/control-plane -o wide
kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o wide
```

`kube-prometheus-stack`, `loki`, `alloy`, and `headlamp` Applications must all show `Synced`/`Healthy`. The Prometheus pod must land on the node listed by the last command (the control-plane node). `pvc/storage-loki-0` and `pv/loki-data` must show `Bound` to each other.

## Verify logs are flowing

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/label/namespace/values' | jq .
```

Expected: a JSON list of namespace names including at least `monitoring`, `headlamp`, `kube-system`, and `envoy-gateway-system` — confirming Alloy is shipping every node's pod logs, not just `monitoring`'s own.

## Reach Grafana and Headlamp

```bash
PUBLIC_IP=15.224.195.86
curl -I --resolve "grafana.$PUBLIC_IP.sslip.io:443:$PUBLIC_IP" "https://grafana.$PUBLIC_IP.sslip.io/"
curl -I --resolve "headlamp.$PUBLIC_IP.sslip.io:443:$PUBLIC_IP" "https://headlamp.$PUBLIC_IP.sslip.io/"
```

Expected: `200` from both once the production ClusterIssuer is in use (spec 2); expect the staging-only `--insecure` flag if spec 2's promotion has not happened yet, matching the networking runbook's staging-vs-production guidance.

Grafana's admin password:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

This local `admin` login is temporary — spec 4 wires Dex/OIDC as the real login path for Grafana and Headlamp alike, and Headlamp's default `cluster-admin` `ClusterRoleBinding` narrows down once that lands.

## Troubleshooting

| Symptom | Checks and corrective action |
| --- | --- |
| `pvc/storage-loki-0` stuck `Pending` | Confirm `pv/loki-data` exists and carries label `app.kubernetes.io/component: loki-data`; the PVC's `selector` must match it and `storageClassName` must be `""` on both sides. |
| Loki pod stuck `ContainerCreating`, event mentions `mount.nfs4` | Confirm `nfs-utils` is installed on the node running the pod (`rpm -q nfs-utils`) and that `/loki` exists on the EFS export — re-run `kubectl -n monitoring get job efs-bootstrap-loki` and check it reached `Complete`. |
| Prometheus pod `Pending`, event mentions node affinity/selector | Confirm the control-plane node still carries `node-role.kubernetes.io/control-plane=true` (`kubectl get nodes --show-labels`) and that its taint is `node-role.kubernetes.io/control-plane:NoSchedule`, matching the toleration in Task 3's values. |
| No logs for a given namespace in Loki | Confirm the Alloy DaemonSet has a `Running` pod on every node, including the control-plane node (`kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy -o wide`); its toleration must match the control-plane taint exactly. |
| `HTTPRoute` not accepted | Run `kubectl -n <namespace> describe httproute <name>`; verify the exact `https` parent reference and that the backend Service name/port match Tasks 3/5. |
| Loki pod `CrashLoopBackOff`, logs show `compactor.delete-request-store should be configured when retention is enabled` | `retention_enabled: true` requires `delete_request_store` to also be set. Confirm `platform/observability/30-loki.application.yaml`'s `loki.compactor` block sets both keys. |
