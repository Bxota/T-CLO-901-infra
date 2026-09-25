# 4. Identity and security runbook

> Operational companion to the [identity and security design](../../../T-CLO-901/docs/superpowers/specs/2026-09-18-kube-design/04-identity-security.md). Design there, exact commands here.

> `kubectl` commands run on `kube-1` as `sudo k3s kubectl` (`export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` makes plain `kubectl` work in the same shell). The OIDC `kubectl` procedure below deliberately uses a *separate* kubeconfig so the cluster-admin one stays untouched.

## Scope

- Keycloak: the identity provider, a workload of the cluster like any other.
- Dex: the OIDC federation layer every tool talks to.
- Coverage: Kubernetes API / `kubectl`, Headlamp, Grafana, Argo CD, all through Dex, no local login left enabled.
- Group-based authorization: `platform-admin`, `developer`, `viewer`.
- The ValidatingAdmissionPolicy on the application namespaces.
- What `playbooks/identity-bootstrap.yml` does and when to run it.

## Who does what

| Component | Deployed by | Configuration | Lives in |
| --- | --- | --- | --- |
| Keycloak 26.6.2 (`codecentric/keycloakx` 7.2.0) | `platform` Application, wave `0`, namespace `identity` | `kc.sh start --import-realm`, realm JSON mounted from Secret `keycloak-realm-config`, bootstrap admin from Secret `keycloak-admin` | `platform/identity/keycloak/` |
| Realm `kubequest2` | Keycloak import at startup | 3 groups, 3 demo users, client `dex`, scopes `email` and `groups` (group mapper without full path) | `playbooks/templates/kubequest2-realm.json.j2` |
| Dex 2.44.0 (`dexidp/dex` 0.24.1) | `platform` Application, wave `1`, namespace `identity` | `config.yaml` from Secret `dex-config`: one `oidc` connector to Keycloak, four static clients | `platform/identity/dex/`, `playbooks/templates/dex-config.yaml.j2` |
| Identity Secrets (`keycloak-admin`, `keycloak-realm-config`, `dex-config`, `argocd-dex-client`, `grafana-dex-client`, `headlamp-dex-client`) | `platform` Application, waves `-1` and `3` | SealedSecrets, unsealed by the controller from [07](07-secrets-registry.md) | `platform/identity/sealed/` |
| Kubernetes API OIDC flags | `playbooks/server.yml` (fresh install and existing node) | `kube-apiserver-arg: oidc-*` in `/etc/rancher/k3s/config.yaml`; re-running the play rewrites it and restarts k3s | `playbooks/server.yml` |
| Group → roles | `platform` Application | `oidc:platform-admin` → `cluster-admin`; `oidc:developer` → `edit` on `app-stage`, `view` on `app` and `monitoring`; `oidc:viewer` → `view` on `app`, `app-stage`, `monitoring`; both get a minimal cluster read (namespaces, nodes) | `platform/identity/rbac/` |
| Argo CD OIDC + RBAC | `playbooks/identity-bootstrap.yml` (imperative patch) | `argocd-cm` `oidc.config`, `admin.enabled: "false"`; `argocd-rbac-cm` `policy.csv` | `playbooks/files/argocd-*-patch.yaml` |
| Grafana OIDC | kube-prometheus-stack Application values | `auth.generic_oauth` against Dex, login form disabled | `platform/observability/20-kube-prometheus-stack.application.yaml` |
| Headlamp OIDC | Headlamp Application values | `config.oidc.externalSecret` = `headlamp-dex-client` | `platform/observability/50-headlamp.application.yaml` |
| ValidatingAdmissionPolicy | `platform` Application | CEL rules on Pods in `app` and `app-stage`, binding action `Deny` | `platform/identity/admission-policy/` |

## Login flow

```text
browser / kubelogin ──► tool (Argo CD, Grafana, Headlamp, kubectl)
                         │  OIDC, client id = argocd | grafana | headlamp | kubernetes
                         ▼
                 Dex  https://dex.bxota.com
                         │  OIDC connector "keycloak", client id = dex
                         ▼
             Keycloak  https://keycloak.bxota.com/realms/kubequest2
                         users, passwords, groups
```

Dex passes through the `email` and `groups` claims from Keycloak. The tools consume them as follows:

| Tool | Identity | `platform-admin` | `developer` | `viewer` | Local login |
| --- | --- | --- | --- | --- | --- |
| Kubernetes API | user `oidc:<email>`, groups `oidc:<group>` | `cluster-admin` | `edit` in `app-stage`, `view` in `app` and `monitoring` | `view` in `app`, `app-stage`, `monitoring` | none (certificates only via the k3s kubeconfig on `kube-1`) |
| Argo CD | `policy.csv` on `groups` | `role:admin` | `role:edit` (readonly + sync, actions, override on `default/app-stage` only, logs everywhere) | `role:readonly` (also the default) | `admin` account disabled |
| Grafana | `role_attribute_path` on `groups` | `GrafanaAdmin` | `Editor` | `Viewer` | login form disabled |
| Headlamp | the user's own ID token is sent to the API | Kubernetes RBAC applies as above | | | none |

Argo CD ships only `role:admin` and `role:readonly`; `role:edit` is defined in `playbooks/files/argocd-rbac-cm-patch.yaml` as readonly plus `applications sync`, `applications action/*` and `applications override` restricted to `default/app-stage`, and `logs get` everywhere. Production (`app-prod`) is never written by hand, neither through kubectl nor through Argo CD: it changes through Git and the `promote` workflow. It is applied by `identity-bootstrap.yml`; after changing the patch file, re-run the play (or apply the patch by hand, see Update the realm or the Argo CD policy below).

## Demo accounts

Defined in the realm export and created at Keycloak startup:

| User | Email | Group |
| --- | --- | --- |
| `alice-admin` | `alice-admin@kubequest2.local` | `platform-admin` |
| `bob-dev` | `bob-dev@kubequest2.local` | `developer` |
| `carol-view` | `carol-view@kubequest2.local` | `viewer` |

Their passwords are the ones in `kubequest2-realm.json.j2`, with `temporary: false`, and each user carries a first and last name. Both matter because Keycloak state is **ephemeral**: the chart values configure no database and no persistent volume, so the realm is re-imported from the Secret on every Keycloak pod start, which happens at least once a day with the nightly VM shutdown. Anything changed through the Keycloak UI (a password, a profile) is lost at the next start; the realm export in Git is the only durable source. Before this fix the users had temporary passwords and no names, so every morning Keycloak asked again for a new password and for first/last name.

If durable self-service accounts ever become a requirement, giving Keycloak a PostgreSQL is a platform change, not a runbook step.

The Keycloak admin console is at `https://keycloak.bxota.com/admin/`, user `admin`, password in Secret `identity/keycloak-admin`:

```bash
kubectl -n identity get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

Use it only to inspect; realm changes go through the template and a re-seal, never through the console.

## Update the realm or the Argo CD policy

The realm export is a SealedSecret whose plaintext contains Keycloak's `dex` client secret, so a template change is a re-seal, not a plain commit. Steps:

1. Edit `playbooks/templates/kubequest2-realm.json.j2` and open the PR.
2. On `kube-1`, read the current `dex` client secret out of the live realm Secret (never print it into a shared terminal recording):

   ```bash
   sudo k3s kubectl -n identity get secret keycloak-realm-config -o jsonpath='{.data.kubequest2-realm\.json}' | base64 -d | jq -r '.clients[] | select(.clientId=="dex") | .secret'
   ```

3. On the workstation, render the template with that value and seal it (same name and namespace, strict scope):

   ```bash
   read -rs DEX_CLIENT_SECRET
   sed "s/{{ dex_client_secret }}/${DEX_CLIENT_SECRET}/" playbooks/templates/kubequest2-realm.json.j2 > /tmp/kubequest2-realm.json
   jq -e . /tmp/kubequest2-realm.json >/dev/null
   kubectl create secret generic keycloak-realm-config --namespace identity --from-file=kubequest2-realm.json=/tmp/kubequest2-realm.json --dry-run=client -o yaml \
     | kubeseal --cert sealed-secrets/pub-cert.pem --format yaml > platform/identity/sealed/keycloak-realm-config.sealedsecret.yaml
   yq -i '.metadata.annotations["argocd.argoproj.io/sync-wave"] = "-1" | .metadata.annotations["argocd.argoproj.io/sync-options"] = "SkipDryRunOnMissingResource=true"' platform/identity/sealed/keycloak-realm-config.sealedsecret.yaml
   rm -f /tmp/kubequest2-realm.json; unset DEX_CLIENT_SECRET
   git diff --cached | grep -c 'kind: Secret$'   # must print 0 after staging
   ```

4. Commit the sealed file in the same PR. After the platform tag is pinned and synced, restart Keycloak so it re-imports. Its StatefulSet uses the `OnDelete` update strategy: `rollout restart` only marks it and the old pod keeps running, so delete the pod:

   ```bash
   sudo k3s kubectl -n identity delete pod keycloak-keycloakx-0
   sudo k3s kubectl -n identity wait --for=condition=Ready pod/keycloak-keycloakx-0 --timeout=5m
   ```

   With `--import-realm`, Keycloak only imports a realm that does not exist yet; on this ephemeral setup every start is a fresh import, which is why the restart is enough.

The Argo CD policy is not GitOps-managed: after editing `playbooks/files/argocd-rbac-cm-patch.yaml` and merging, apply it on `kube-1` with either the play or the patch directly:

```bash
cd ~/T-CLO-901-infra && git pull && sudo ansible-playbook playbooks/identity-bootstrap.yml
# or
sudo k3s kubectl -n argocd patch configmap argocd-rbac-cm --type merge --patch-file playbooks/files/argocd-rbac-cm-patch.yaml
```

Argo CD reloads `argocd-rbac-cm` without a restart. Check with `argocd admin settings rbac can developer sync applications '*/*' --policy-file playbooks/files/argocd-rbac-cm-patch.yaml` from a workstation with the CLI, or simply log in as `bob-dev` and press Sync.

## Bootstrap and rebuild

Run on `kube-1`, after `argocd-bootstrap.yml` ([03](03-gitops.md)) and only once the `platform` Application has synced, so the SealedSecrets controller has unsealed the identity Secrets:

```bash
sudo k3s kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/platform --timeout=15m
sudo k3s kubectl -n identity get secret dex-config      # must exist before the next line
cd ~/T-CLO-901-infra && sudo ansible-playbook playbooks/identity-bootstrap.yml
```

What the play does:

1. Clones the infra repo to `/tmp` for its templates.
2. Checks for `identity/dex-config`. **If it exists** (normal case, SealedSecrets synced), every secret-generation task is skipped. **If it does not** (first ever bootstrap, or a rebuild without the sealing key), it generates the Keycloak admin password and the four client secrets with `openssl rand`, renders the realm and Dex templates, creates the six Secrets, then shreds the rendered files. Running the generation path on a cluster that already has the SealedSecrets would desynchronise Keycloak's `dex` client secret from Dex's copy; the existence check is what prevents that.
3. Patches `argocd-cm` (Dex issuer, client `argocd`, `admin.enabled: "false"`) and `argocd-rbac-cm` (group policy), then restarts `argocd-server`.

Order of appearance after a sync: Keycloak becomes Ready first (wave `0`), Dex follows (wave `1`, its connector needs Keycloak's discovery document), Grafana and Headlamp receive their client Secrets at wave `3`.

## Verify the chain

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n identity get pods
kubectl -n identity get secret keycloak-admin keycloak-realm-config dex-config grafana-dex-client headlamp-dex-client
kubectl -n argocd get secret argocd-dex-client
curl -fsS https://keycloak.bxota.com/realms/kubequest2/.well-known/openid-configuration | head -c 200; echo
curl -fsS https://dex.bxota.com/.well-known/openid-configuration | head -c 200; echo
grep -o 'oidc-[a-z-]*=[^ ]*' /etc/systemd/system/k3s.service
kubectl -n argocd get configmap argocd-cm -o jsonpath='{.data.admin\.enabled}{"\n"}{.data.oidc\.config}'
kubectl get clusterrolebinding oidc-platform-admin oidc-developer oidc-viewer
```

The two `curl` calls run from `kube-1` on purpose: the API server fetches Dex's keys through the same public hostname when it validates a token, so Dex must be reachable from the control plane.

## `kubectl` through OIDC

This is the one coverage item without a browser UI, and the one graders ask about. The procedure runs **on `kube-1`**: the API is reached on `https://127.0.0.1:6443`. Dex's `kubernetes` client is public, and Dex accepts the out-of-band redirect (`urn:ietf:wg:oauth:2.0:oob`) for public clients, so kubelogin's keyboard flow works without touching the Dex config.

Install [kubelogin](https://github.com/int128/kubelogin) once (Amazon Linux 2023, x86_64; adjust the version to the latest release):

```bash
KUBELOGIN_VERSION=v1.34.0
curl -fsSL "https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_linux_amd64.zip" -o /tmp/kubelogin.zip
sudo unzip -o /tmp/kubelogin.zip kubelogin -d /usr/local/bin
sudo mv /usr/local/bin/kubelogin /usr/local/bin/kubectl-oidc_login
kubectl oidc-login --version
```

Build a dedicated kubeconfig. The CA is the k3s server CA; the user entry is an exec credential plugin:

```bash
mkdir -p ~/.kube
sudo cat /var/lib/rancher/k3s/server/tls/server-ca.crt > ~/.kube/k3s-server-ca.crt
export KUBECONFIG=~/.kube/oidc.yaml

kubectl config set-cluster kubequest2 --server=https://127.0.0.1:6443 --certificate-authority=$HOME/.kube/k3s-server-ca.crt --embed-certs=true
kubectl config set-credentials oidc \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login \
  --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://dex.bxota.com \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-extra-scope=email \
  --exec-arg=--oidc-extra-scope=groups \
  --exec-arg=--grant-type=authcode-keyboard
kubectl config set-context oidc --cluster=kubequest2 --user=oidc
kubectl config use-context oidc
```

Log in and prove who the API sees:

```bash
kubectl auth whoami
```

kubelogin prints a URL. Open it in your own browser, log in on Keycloak as `alice-admin`, copy the code Dex shows and paste it back into the terminal. Expected output:

```text
ATTRIBUTE   VALUE
Username    oidc:alice-admin@kubequest2.local
Groups      [oidc:platform-admin system:authenticated]
```

Then show the authorization side. Tokens are cached under `~/.kube/cache/oidc-login/`; clear the cache to switch user:

```bash
kubectl get nodes                                    # alice: allowed (cluster-admin)
rm -rf ~/.kube/cache/oidc-login
kubectl auth whoami                                  # log in as carol-view this time
kubectl get pods -n app                              # allowed (view)
kubectl get pods -n identity                         # Forbidden: viewer has no right in identity
kubectl -n app delete pod -l app.kubernetes.io/name=laravel --dry-run=server
# Error from server (Forbidden): ... User "oidc:carol-view@kubequest2.local" cannot delete resource "pods" ...
kubectl auth can-i delete pods -n app                # no
rm -rf ~/.kube/cache/oidc-login
kubectl auth whoami                                  # bob-dev
kubectl auth can-i delete pods -n app-stage          # yes (edit on stage)
kubectl auth can-i delete pods -n app                # no  (view on prod)
```

Never point this kubeconfig at the cluster-admin credentials; keep `KUBECONFIG` unset in other shells so `sudo k3s kubectl` keeps working as before.

Tailnet variant, from a team laptop (enabled, not part of the defence): the API server's certificate also covers `kube-1`'s Tailscale IP (`tls-san` in `server.yml`) and the tailnet ACL admits TCP 6443 from team members, while port 6443 stays closed in the AWS security group. Copy `/var/lib/rancher/k3s/server/tls/server-ca.crt` from `kube-1`, then use the same kubeconfig with `--server=https://100.89.166.31:6443` and `--grant-type=authcode` (browser opens on `http://localhost:8000`, the redirect URI already declared for the `kubernetes` client).

## Tool logins for the defence

| Tool | URL | What to show |
| --- | --- | --- |
| Argo CD | `https://argocd.bxota.com` | Only a "Log in via Dex" button, no username form. `alice-admin` has every action; `bob-dev` can sync but not create or delete Applications; `carol-view` sees everything read-only, `Sync` is refused. `admin` password login fails |
| Grafana | `https://grafana.bxota.com` | Redirect straight to Dex. `alice-admin` lands as Grafana Admin (Administration menu visible), `bob-dev` as Editor, `carol-view` as Viewer |
| Headlamp | `https://headlamp.bxota.com` | "Sign in" goes to Dex. `carol-view` can list but the Delete action is refused by the API (Headlamp uses the user's own token) |
| Keycloak | `https://keycloak.bxota.com/admin/` | Realm `kubequest2`, Groups, Users, client `dex`. Show that it is config, not clicks: the same content is in `kubequest2-realm.json.j2` |

Use a private browser window per user, or log out of Keycloak between users: Dex and Keycloak keep a session, so a second tool login reuses the previous identity.

## Admission policy

`platform/identity/admission-policy/validatingadmissionpolicy.yaml` binds one policy, `app-namespace-guardrails`, with `validationActions: [Deny]` to Pods created or updated in `app` and `app-stage`. Three rules:

| Rule | CEL | Refusal message |
| --- | --- | --- |
| Mandatory label | `'app.kubernetes.io/name' in object.metadata.labels` | "Pods in application namespaces must carry the 'app.kubernetes.io/name' label." |
| Requests and limits on every container | `object.spec.containers.all(c, has(c.resources.requests) && has(c.resources.limits))` | "Every container in application namespaces must declare resource requests and limits." |
| Approved registry | `object.spec.containers.all(c, c.image.startsWith('ghcr.io/bxota/'))` | "Container images in application namespaces must come from ghcr.io/bxota/ (the approved private registry)." |

The policy is scoped to Pods, so a Deployment is accepted and its ReplicaSet then fails to create Pods; look at `kubectl -n app-stage get rs` and `describe rs` for the message. The application chart mirrors every vendor image (MySQL, busybox) into GHCR because of the third rule, see [06](06-application.md#admission-policy-and-image-mirror-contract).

Live proof, each command must be **refused** with the matching message:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get validatingadmissionpolicy app-namespace-guardrails
kubectl get validatingadmissionpolicybinding app-namespace-guardrails-binding

# 1. no label
kubectl -n app-stage run vap-test --image=ghcr.io/bxota/busybox:1.37.0 --restart=Never --command -- sleep 1
# 2. label but no resources
kubectl -n app-stage run vap-test --image=ghcr.io/bxota/busybox:1.37.0 --restart=Never \
  --labels=app.kubernetes.io/name=vap-test --command -- sleep 1
# 3. label, resources, but a public image
kubectl -n app-stage run vap-test --image=busybox:1.37.0 --restart=Never \
  --labels=app.kubernetes.io/name=vap-test \
  --overrides='{"spec":{"containers":[{"name":"vap-test","image":"busybox:1.37.0","command":["sleep","1"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"10m","memory":"16Mi"}}}]}}'
```

Control case, **accepted** (then deleted):

```bash
kubectl -n app-stage run vap-test --image=ghcr.io/bxota/busybox:1.37.0 --restart=Never \
  --labels=app.kubernetes.io/name=vap-test \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}],"containers":[{"name":"vap-test","image":"ghcr.io/bxota/busybox:1.37.0","command":["sleep","1"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"10m","memory":"16Mi"}}}]}}'
kubectl -n app-stage delete pod vap-test
```

The policy does not apply outside `app` and `app-stage` (`matchConditions`), so system namespaces are never at risk from it.

## Troubleshooting

- **Keycloak login says invalid credentials for a demo user.** State is ephemeral; the only valid password is the one in the realm template. Anything changed via the UI was lost at the last restart.
- **Dex shows "failed to connect to keycloak" / CrashLoop.** Keycloak is not Ready yet, still serves an old hostname, or its discovery URL is unreachable from the pod. `kubectl -n identity logs deploy/dex`, then `curl` the realm's `.well-known` from `kube-1`. Dex retries on its own with crash-loop back-off (up to 5 minutes); `kubectl -n identity delete pod <dex pod>` retries at once.
- **Dex "invalid client secret" from Keycloak.** `dex-config` and `keycloak-realm-config` were generated at different times. Both must come from the same run: either the SealedSecrets pair in Git or the same execution of `identity-bootstrap.yml`. Never mix a sealed one with a regenerated one.
- **Token accepted by Dex but `kubectl` says Unauthorized.** Check the six `oidc-*` entries in `/etc/rancher/k3s/config.yaml` (list items ending with `:` must be quoted, or k3s fails to start) and that the API server can reach `https://dex.bxota.com` from `kube-1`. `journalctl -u k3s | grep -i oidc` shows the verification error.
- **`kubectl auth whoami` shows no `oidc:<group>` entry.** The token lacks the `groups` claim: check the two `--oidc-extra-scope` args, and in Keycloak that the `groups` client scope is a default scope of the `dex` client (it is in the template).
- **Argo CD still shows the username/password form.** `identity-bootstrap.yml` has not patched `argocd-cm`, or `argocd-server` was not restarted. Re-run the play; it is idempotent on this part.
- **Grafana "login.OAuthLogin(NewTransportWithCode)" error.** Redirect URI mismatch: Grafana's `root_url` must be exactly `https://grafana.bxota.com` and Dex's `grafana` client must list `/login/generic_oauth` under it.
- **Headlamp signs in but every list is Forbidden.** Kubernetes RBAC, not Headlamp: the user's groups have no binding. Check `kubectl auth whoami` for the same user through kubelogin.
- **A legitimate pod is refused in `app-stage`.** Read the exact CEL message; the usual case is a vendor image not yet mirrored under `ghcr.io/bxota/`.

## Defence checklist

1. Keycloak admin console: realm, groups, users; point at the template in Git.
2. Argo CD, Grafana, Headlamp: log in as `alice-admin` then `carol-view`, show the role difference and that no local login exists.
3. `kubectl auth whoami` through kubelogin on `kube-1` for the three users: `auth can-i delete pods -n app` is `yes` for `alice-admin`, `no` for `bob-dev` and `carol-view`; `-n app-stage` is `yes` for `bob-dev`.
4. `grep oidc /etc/systemd/system/k3s.service`: the API server itself is OIDC-configured, not only the tools.
5. The three refused `kubectl run` commands against the admission policy, then the accepted control case.

## Changing an identity URL

The Dex config and the Keycloak realm are sealed and hold client secrets and user passwords, so a URL change is re-sealed **on `kube-1`**, from the live Secrets, and only ciphertext leaves the node:

```bash
umask 077; cd "$(mktemp -d)"
curl -sSL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/kubeseal-0.40.0-linux-amd64.tar.gz | tar -xz kubeseal
curl -sSLo pub-cert.pem https://raw.githubusercontent.com/Bxota/T-CLO-901-infra/main/sealed-secrets/pub-cert.pem
sudo k3s kubectl -n identity get secret dex-config -o jsonpath='{.data.config\.yaml}' | base64 -d > dex.yaml
sudo k3s kubectl -n identity get secret keycloak-realm-config -o jsonpath='{.data.kubequest2-realm\.json}' | base64 -d > realm.json
sed -i 's#<old host>#<new host>#g' dex.yaml realm.json       # URLs only
grep -n 'https://' dex.yaml realm.json                         # check: no secret is on these lines
./kubeseal --raw --cert pub-cert.pem --namespace identity --name dex-config --from-file=dex.yaml
./kubeseal --raw --cert pub-cert.pem --namespace identity --name keycloak-realm-config --from-file=realm.json
shred -u dex.yaml realm.json
```

Replace the `config.yaml` and `kubequest2-realm.json` values in `platform/identity/sealed/` with the two outputs. `headlamp-dex-client.OIDC_ISSUER_URL` is not secret and can be sealed from a workstation (`kubeseal --raw --namespace headlamp --name headlamp-dex-client --from-file=<file holding the URL>`). Change the same URLs in the plain-text files (`scripts/check-exposure-config.sh` lists them and fails while one still has the old host).

After the release tag syncs, in this order (a login outage of a few minutes):

1. Keycloak first: delete `keycloak-keycloakx-0` and wait for Ready (above). Dex checks its connector at start; a Dex started before Keycloak has its new hostname crash-loops.
2. `sudo k3s kubectl -n identity rollout restart deploy/dex` and `sudo k3s kubectl -n headlamp rollout restart deploy/headlamp`.
3. `ansible-playbook server.yml` (API server issuer; restarts k3s) and `ansible-playbook identity-bootstrap.yml` (`argocd-cm`, restarts `argocd-server`).
4. `curl -s https://dex.bxota.com/.well-known/openid-configuration | grep -o '"issuer": *"[^"]*"'`, then log in on each tool.
