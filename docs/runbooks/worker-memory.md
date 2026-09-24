# Worker memory budgets and redistribution

## Evidence and scope

On 2026-09-24, node-exporter reported 83.9% memory used on node-2
(`10.0.0.109`) and 33.6% on node-3 (`10.0.0.198`), each with 3830 MiB
of RAM. The Grafana panel uses `1 - MemAvailable / MemTotal`, including
host processes. `kubectl top` uses a different memory measurement and need
not show the same percentage. Both workers had `MemoryPressure=False`.

Keycloak, Grafana, both MySQL instances, the Argo CD application controller
and Loki were on node-2. Several had no memory requests. Its total requested
memory was only 1018 MiB (26%), despite actual use above 80%. Kubernetes
schedules using requests, not Grafana's observed usage, and does not move
running pods merely to equalize memory consumption.

The following initial budgets use the maximum available samples in a 24-hour
Prometheus window, including old pod names. These samples are not a load test
or a guarantee of future peaks. Revisit after startup, deployment, backup and
normal traffic cycles. CPU requests are modest starting reservations; CPU
limits are not added to platform services. Existing MySQL CPU settings remain.

| Container | Observed peak MiB | Request | Limit |
| --- | ---: | ---: | ---: |
| Keycloak | 829 | 1Gi | 2Gi |
| Grafana | 646 | 640Mi | 1Gi |
| Each Grafana sidecar | 77–79 | 96Mi | 192Mi |
| Argo CD application controller | 594 | 640Mi | 1Gi |
| MySQL prod / stage | 433 / 446 | 512Mi each | 1Gi each (unchanged) |
| Loki | 151 | 256Mi | 768Mi |
| Loki rules sidecar | 89 | 96Mi | 192Mi |
| Alloy (maximum across nodes) | 187 | 256Mi per node | 512Mi |
| Alloy config reloader | 17 (all reloaders) | 50Mi | 128Mi |
| Prometheus | 829 | 1Gi | 2Gi |
| Alertmanager | 26 | 64Mi | 256Mi |

Grafana has **preferred** cross-namespace pod anti-affinity against Keycloak
on `kubernetes.io/hostname`. It encourages separation without pinning IPs or
preventing recovery when only one worker is available. This is not a guarantee
of equal percentages. Laravel's existing production anti-affinity is retained.
Node-1 remains reserved for the control plane and existing tolerated workloads;
Prometheus retains its existing node selector and local volume.

## Keycloak rollout hold — real data-loss risk

The live Keycloak pod has `/opt/keycloak/data/h2/keycloakdb.mv.db`, no data PVC,
and no external database configuration. The only mounted volume is the realm
import Secret. Replacing the pod can lose users/configuration added after that
import. Its new resource budget is therefore staged with StatefulSet
`updateStrategy: OnDelete`: syncing changes the template but **does not apply
the budget to the existing pod**. Do not delete or restart this pod to force
the update. OnDelete does not protect against involuntary pod loss and also
defers future image/template updates until an explicit replacement.

Before activating the budget, arrange a maintenance window, preserve the
current realm/users with a supported consistent backup/export, and verify
restoration to persistent database storage. A live copy of the open H2 file
is not a verified backup. Migrating identity storage is a separate change;
do not add a blank PVC and assume it contains the existing data. Once restored
and validated, change `updateStrategy` back to `RollingUpdate`, roll Keycloak,
then verify existing users and the Dex/Grafana/Argo CD login flows. In the same
change, drop the `OnDelete` assertion from `scripts/check-memory-resources.py`;
the lint job otherwise rejects the restored strategy.

Keycloak's JVM sizes its heap relative to the container memory limit; the
2Gi limit retains startup/non-heap headroom. See [Keycloak container memory
configuration](https://www.keycloak.org/server/containers).

## Validate before publishing

```bash
kubectl kustomize platform > /tmp/platform.yaml
python3 scripts/check-memory-resources.py
python3 scripts/check-memory-alerts.py
bash scripts/check-dashboards.sh
ansible-playbook -i localhost, --syntax-check playbooks/argocd-resources.yml
ansible-playbook -i localhost, --syntax-check playbooks/argocd-bootstrap.yml
```

The Python checks require PyYAML, Helm and promtool. The resource check renders
the pinned charts and checks real container resources, including sidecars;
`CHART_CACHE` may point to already downloaded chart archives. The alert test
covers a sustained deficit, a brief spike, the exact threshold and recovery.
The warning fires below 20% available memory for 15 minutes and uses the
existing warning receiver. Existing upstream Kubernetes restart/OOM alerts
remain enabled. A notification being delivered is an operational check, not
covered by the local tests.

## Controlled deployment

These source changes do not themselves prove the workers are rebalanced.
Keep a read-only before/after snapshot (`top nodes`, `top pods -A`, `get pods
-A -o wide`, node conditions, pending pods and restart counts).

1. Apply the Argo CD controller patch from a reviewed checkout **on kube-1**:
   `ansible-playbook playbooks/argocd-resources.yml`. Argo CD is installed by
   Ansible, not by a Helm Application. The strategic merge patch retains its
   image, probes, volumes and other container fields and waits for its rollout.
   The same patch is included in bootstrap for rebuilds. Check controller
   readiness and reconciliation before proceeding.
2. Publish the reviewed platform release through the existing tag/pin workflow.
   `platform/apps/platform.yaml` is pinned to a version; a main-branch merge
   alone does not update its Helm Applications. Monitor the Grafana rollout
   first: its placement preference should relieve node-2. Check Loki, Alloy,
   Prometheus and Alertmanager readiness and their restart counters. Their
   single replicas can cause brief service/monitoring interruptions during
   rollout. Grafana has no configured persistent database either: provisioned
   dashboards return from Git, but preserve any UI-only changes beforehand.
3. Apply the MySQL overrides sequentially, checking readiness after each.
   Unlike platform components, `platform/apps/app-{prod,stage}.yaml` is watched
   directly from **main** by the root Application: merging both overrides
   together can start both database rollouts immediately. Split their merges
   for an operationally sequential rollout. Confirm a usable production backup
   before its maintenance window. Stage's local-path PVC stays attached to
   node-2; do not delete it, drain its node, or migrate its data for balancing.
4. Confirm Keycloak's current pod UID is unchanged; its resources remain the
   old values until the persistence prerequisite above is resolved. Account
   for its actual consumption when judging node-2 headroom meanwhile.
5. Inspect memory after stabilization and during the next activity cycle.
   Aim for at least 20% available on each worker, no new OOMKilled containers,
   no Pending pods, and stable readiness. Do not claim this target from
   rendered manifests alone. If a container hits its limit, inspect its peak
   and logs before increasing it; limits are ceilings, not memory savings.

All Kubernetes commands below run on kube-1 using `sudo k3s kubectl`:

```bash
sudo k3s kubectl top nodes
sudo k3s kubectl top pods -A --sort-by=memory
sudo k3s kubectl get pods -A -o wide
sudo k3s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}{end}'
sudo k3s kubectl -n monitoring rollout status deployment/kube-prometheus-stack-grafana --timeout=300s
sudo k3s kubectl -n app-stage rollout status statefulset/mysql --timeout=300s
sudo k3s kubectl -n app rollout status statefulset/mysql --timeout=300s
```

For the same historical measurement used to choose these budgets:

```promql
max by (namespace, container) (
  max_over_time(container_memory_working_set_bytes{
    container!="", container!="POD",
    namespace=~"identity|monitoring|argocd|app|app-stage"
  }[24h])
) / 1024 / 1024
```

## Rollback

Revert the relevant resource/affinity changes in Git and publish/pin the
reviewed rollback release; revert MySQL overrides on main separately.
Do not blindly revert Keycloak's OnDelete hold: restoring RollingUpdate
while the template differs would recreate its unprotected database.
For the Ansible-owned controller, restore its previous resources using a
strategic patch (the observed previous configuration was `resources: {}`;
patch `resources: null` to remove the newly added fields), then wait for
the controller rollout. Do not delete PVCs as part of any rollback.

A Descheduler or more nodes can be considered after these budgets and real
headroom have been observed. Neither is needed to correct the missing requests.
