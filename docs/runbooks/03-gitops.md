# 3. GitOps (Argo CD) runbook

> Operational companion to the [GitOps design](../../../T-CLO-901/docs/superpowers/specs/2026-09-18-kube-design/03-gitops.md) and the [release tags design](../../../T-CLO-901/docs/superpowers/specs/2026-09-21-release-tags-design.md). Design there, exact commands here. Promotion and rollback of releases are in [08-release-process.md](08-release-process.md).

> `kubectl` commands run on `kube-1` as `sudo k3s kubectl` (`export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` makes plain `kubectl` work in the same shell). There is no workstation kubeconfig for cluster-admin work; OIDC access for `kubectl` is described in [04-identity-security.md](04-identity-security.md).

## Scope

Argo CD is the only writer of workloads in the cluster. Everything below `argocd-bootstrap.yml` is declared in Git and reconciled by the operator; nobody runs `kubectl apply`, `helm install` or `kubectl set image` against the platform or the application by hand. This runbook covers:

- installing Argo CD and the root Application with Ansible;
- the app-of-apps layout and the sync-wave order of the `platform` Application;
- how a Git change reaches the cluster (platform tag, application chart range);
- inspecting sync and health, which is what the defence is graded on;
- recovering a stuck sync.

## Responsibilities

| Layer | Owned by | Lives in |
| --- | --- | --- |
| Argo CD itself (namespace `argocd`, upstream `stable` manifest) | `playbooks/argocd-bootstrap.yml` | infra repo, applied once per cluster build |
| `root` Application | `playbooks/argocd-bootstrap.yml` | infra `argocd/apps/root.yaml`, applied once; then self-managed |
| `platform`, `app-prod`, `app-stage` Applications | `root` (app-of-apps, `platform/apps` kustomization) | infra `platform/apps/*.yaml` |
| Platform components (networking, secrets, identity, observability, admission policy) | `platform` Application | infra `platform/`, pinned to a `vX.Y.Z` tag |
| Laravel application + MySQL subchart | `app-prod` / `app-stage` Applications | OCI chart `ghcr.io/bxota/charts/laravel`, published by the app repo CI |
| Argo CD OIDC and RBAC ConfigMaps (`argocd-cm`, `argocd-rbac-cm`, `server.insecure`) | `playbooks/identity-bootstrap.yml` and `argocd-bootstrap.yml` | ConfigMap patches under `playbooks/files/` |

The Argo CD ConfigMaps are the one exception to "everything through the `platform` Application": Argo CD cannot be made to depend on itself for its own OIDC login, so the two playbooks patch them imperatively. The patches are still versioned files.

## Bootstrap on a fresh cluster

Order matters. Run on `kube-1`, after `server.yml` / `agent.yml` ([01-cluster-initialization.md](01-cluster-initialization.md)) and `sealed-secrets-restore.yml` ([07-secrets-registry.md](07-secrets-registry.md)):

```bash
cd ~/T-CLO-901-infra && git pull            # clone the repo on kube-1 rather than pasting playbooks; pasted copies go stale
sudo ansible-playbook playbooks/argocd-bootstrap.yml
sudo k3s kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/platform --timeout=15m
sudo ansible-playbook playbooks/identity-bootstrap.yml   # only after the wait above: see the gate in 07
```

What `argocd-bootstrap.yml` does, in order:

1. Creates the `argocd` namespace and applies the upstream `stable` install manifest server-side (skipped when the namespace already exists, so the play is re-runnable).
2. Waits for `deployment/argocd-server` to be available.
3. Clones the infra repo to `/tmp` and deletes the legacy `Application/app` with `--cascade=orphan`, so workloads from the pre-tag era survive while `app-prod` becomes their sole owner. Do not apply `app-prod` before this step on a migrated cluster: two automated owners would fight over the same resources.
4. Applies `argocd/apps/root.yaml`. From here on, Argo CD owns everything.
5. Sets `server.insecure: "true"` in `argocd-cmd-params-cm` and restarts `argocd-server`: TLS terminates on the public Gateway, Argo CD serves plain HTTP behind it.

The Argo CD UI is reachable at `https://argocd.bxota.com` (HTTPRoute in `platform/argocd-ui/`, synced by `platform`). The local `admin` account is disabled once `identity-bootstrap.yml` has run; login is through Dex (see 04). Until then, the initial admin password is in `secret/argocd-initial-admin-secret`.

## App-of-apps layout

```text
argocd/apps/root.yaml                  Application "root"  → infra repo, branch main, path platform/apps
platform/apps/kustomization.yaml
├── platform.yaml                      Application "platform"  → infra repo, tag vX.Y.Z, path platform/
├── app-prod.yaml                      Application "app-prod"  → OCI chart laravel, range >=1.0.0,   namespace app
└── app-stage.yaml                     Application "app-stage" → OCI chart laravel, range >=1.0.0-0, namespace app-stage
platform/kustomization.yaml            namespaces, networking, argocd-ui, secrets, identity, observability
```

All four Applications use `automated: {prune: true, selfHeal: true}` and `CreateNamespace=true`. Consequences:

- a manual `kubectl edit` on a managed resource is reverted within minutes (`selfHeal`);
- a resource removed from Git is deleted from the cluster (`prune`);
- `root` tracks `main` directly, so a merge that touches `platform/apps/` takes effect at the next refresh (3 minutes by default), while `platform` moves only when its `targetRevision` tag changes.

Per-environment Helm values (hostname, replica count, EFS PV selector, sealed ciphertexts) live in `valuesObject` of `app-prod.yaml` and `app-stage.yaml`. The chart's own `values.yaml` ships no ciphertext and no selector; see the incident note below for why.

## Sync order inside `platform`

Argo CD applies a wave only after every resource of the previous wave is Synced and Healthy. Child Applications count as resources, so a Helm release must be fully up before the next wave starts.

| Wave | Resources | Why here |
| --- | --- | --- |
| `-3` | Namespaces (`envoy-gateway-system`, `cert-manager`, `identity`, `app`, `app-stage`) | Everything else targets them |
| `-2` | Envoy Gateway Application (Gateway API CRDs), Sealed Secrets controller Application | CRDs for routes; controller to unseal wave `-1` |
| `-1` | cert-manager Application; identity SealedSecrets (`keycloak-admin`, `keycloak-realm-config`, `dex-config`, `argocd-dex-client`) | cert-manager needs Gateway API CRDs present at startup |
| `0` | EnvoyProxy, GatewayClass, ClusterIssuers, Keycloak Application | Gateway infrastructure and the identity provider |
| `1` | Public Gateway, Certificates, Dex Application, Keycloak HTTPRoute | Dex needs Keycloak reachable to start its connector |
| `2` | Dex HTTPRoute, `monitoring` namespace, Loki EFS bootstrap Job, Loki PV | Storage before the stacks |
| `3` | kube-prometheus-stack, Loki, Alloy, Headlamp Applications; Grafana and Headlamp Dex client SealedSecrets | The observability stacks and their OIDC clients |
| `4` | Observability HTTPRoutes, PrometheusRules, ServiceMonitors, Envoy PodMonitor | Need the CRDs installed by wave `3` |

Resources whose CRD is installed by a child Application in an earlier wave carry `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`, otherwise the parent's initial dry run fails before the child has installed the CRD.

The application chart has its own internal order (PreSync EFS bootstrap → PV/config → MySQL → optional restore Job → migration Job → Deployment), documented in [06-application.md](06-application.md#argo-cd-sync-order).

## How a change reaches the cluster

**Platform change.** Merge to `main` in the infra repo (lint workflow: `kustomize build`, `promtool`, dashboard checks). Nothing deploys yet. Tag the reviewed commit:

```bash
git tag v1.3.0 && git push origin v1.3.0
```

The `pin-release` workflow commits `targetRevision: v1.3.0` into `platform/apps/platform.yaml` on `main`; `root` picks that up and `platform` reconciles the tag. A platform rollback is the same edit to an earlier tag.

**Application change.** Merge a Conventional Commit PR to `main` in the app repo. `release-candidate` builds the image, pushes the OCI chart and creates `vX.Y.Z-rc.N`. `app-stage` follows `>=1.0.0-0` and picks the rc up at its next refresh. Run `promote` to create the stable `vX.Y.Z`; `app-prod` follows `>=1.0.0`. Details and rollback: [08-release-process.md](08-release-process.md).

In both cases the cluster is never touched directly. For the defence, show the Git commit or tag, then the Application's `Sync` and `Health` columns turning `Synced` / `Healthy`.

## Inspect sync and health

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# The four Applications, their tracked revision, sync and health
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,REV:.spec.source.targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status,OP:.status.operationState.phase

# Detail of one Application: conditions, last operation, out-of-sync resources
kubectl -n argocd describe application platform | sed -n '/Status:/,$p'

# Force a refresh (re-read Git / the OCI registry) without waiting for the poll interval
kubectl -n argocd annotate application app-stage argocd.argoproj.io/refresh=hard --overwrite

# Which chart version an app is actually running
kubectl -n argocd get application app-prod -o jsonpath='{.status.sync.revision}{"\n"}'
```

Expected steady state: every Application `Synced` and `Healthy`, `OP` empty or `Succeeded`. `Progressing` is normal during a rollout; `Degraded` on `app-prod` or `app-stage` right after a release is the broken-readiness case demonstrated in 06, not something to fix from the Argo CD side.

Argo CD 3 no longer persists per-resource health in `status.resources`; use the UI resource tree or `argocd app resources <app>` for that level.

## Troubleshooting

- **Application `OutOfSync` and stays so.** Read `status.conditions`: a `ComparisonError` usually means the OCI chart version does not exist yet, the GHCR package is private, or a values key has the wrong type. `describe` names the offending resource.
- **Sync stuck on a hook Job.** A `Sync`/`PreSync` hook Job that never starts (missing image, admission denial, unschedulable pod) blocks every later sync until its `activeDeadlineSeconds`. Recover:

  ```bash
  kubectl -n argocd patch application app-stage --type merge -p '{"operation":null}'
  kubectl -n app-stage delete job -l app.kubernetes.io/instance=app-stage --field-selector status.successful=0
  kubectl -n argocd annotate application app-stage argocd.argoproj.io/refresh=hard --overwrite
  ```

  Then fix the cause in Git; do not re-run the Job by hand.
- **Admission denied in `app` / `app-stage`.** Check the three rules of the ValidatingAdmissionPolicy (`app.kubernetes.io/name` label, requests and limits on every container, image under `ghcr.io/bxota/`). Vendor images must be mirrored into GHCR, see 06.
- **`ImagePullBackOff` from GHCR.** The pull secret is a *classic* PAT with `read:packages`, sealed per namespace in `app-prod.yaml` / `app-stage.yaml`. Chart packages must be public, images private. See 07.
- **A Helm default cannot be removed per environment.** Argo CD's Helm keeps a subchart default when the override is `null`, and `{}` merges into it. Anything that one environment must *not* have (the prod EFS PV `selector` for instance) must be absent from chart defaults and set only in that environment's `valuesObject`.
- **CronJob shows `Degraded` after a release.** Argo CD 3 marks a CronJob Degraded until its next scheduled run succeeds; a manual `kubectl create job --from=cronjob/...` does not clear it. Wait for the schedule or check the last Job's logs.
- **`root` did not pick up a merged change.** `root` polls `main` every 3 minutes; hard-refresh it. If `platform` did not move after a tag, check that `pin-release` ran and that `platform/apps/platform.yaml` now carries the tag.
- **Argo CD UI login fails after a rebuild.** `identity-bootstrap.yml` must have patched `argocd-cm` and `argocd-rbac-cm` and restarted `argocd-server`; see 04.

## Defence checklist

1. `kubectl -n argocd get applications` : four Applications, all `Synced` / `Healthy`.
2. Argo CD UI, `platform` app: point at the sync-wave order and at the child Applications.
3. Show `platform/apps/platform.yaml` pinned to a tag, and the `pin-release` commit that wrote it.
4. Merge or promote an app release and watch `app-stage` / `app-prod` reconcile without any `kubectl` write.
5. Follow with the broken-readiness demonstration in [06-application.md](06-application.md#deliberate-broken-readiness-demonstration).
