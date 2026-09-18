# T-CLO-901 infra

Infrastructure repository for the T-CLO-901 KUBE project: cluster provisioning (this document) plus the platform components (ingress, monitoring, logging, identity, security) added in later work.

## Cluster provisioning

The three-node k3s cluster (`kube-1` control-plane, `kube-2`/`kube-3` workers) is provisioned with Ansible, but **each node runs its own play locally** rather than being driven remotely from a workstation. This is a deliberate adaptation to the lab's IAM policy, not the original design:

- The `community.aws`/`amazon.aws` `aws_ssm` Ansible connection plugin unconditionally requires an S3 bucket for file transfer (confirmed by reading the plugin source across both the distro-packaged version and the latest release from Galaxy) — the lab's `kubequest2-student` IAM role has no S3 permissions at all.
- `ssm:SendCommand` and `ssm:StartSession` on the `AWS-StartSSHSession` document are both denied by the same role, ruling out remote command execution and SSH-over-SSM tunneling as well.
- The only permitted action is a plain interactive `aws ssm start-session --target <instance-id>` (the default session document).

Given that, each instance installs Ansible locally (`sudo dnf install -y ansible-core git` on Amazon Linux 2023) and runs a `connection: local` play against itself. `kube-1` runs `playbooks/server.yml`, which prints the cluster join token and its own private IP; that token and IP are passed by hand as extra-vars to `playbooks/agent.yml` on `kube-2` and `kube-3`. Design rationale for the cluster itself lives in the coordination repo at `docs/superpowers/specs/2026-09-18-kube-design/01-cluster-provisioning.md`; the exact step-by-step commands live at `docs/runbooks/01-cluster-initialization.md` in that same repo.

### Running it

Since these instances have no Git credentials and no path to pull this repo directly, the play content is pasted onto each instance via the SSM session (heredoc). On **kube-1**:

```bash
export AWS_PROFILE=kubequest2
aws ssm start-session --target <kube-1-instance-id>
```

```bash
sudo dnf install -y ansible-core git
cat > ~/server.yml << 'EOF'
# paste the contents of playbooks/server.yml here
EOF
ansible-playbook ~/server.yml
```

Copy the `PRIVATE_IP=` and `TOKEN=` values from the last task's output. Then, on **kube-2** and **kube-3** (separate SSM sessions):

```bash
sudo dnf install -y ansible-core git
cat > ~/agent.yml << 'EOF'
# paste the contents of playbooks/agent.yml here
EOF
ansible-playbook ~/agent.yml -e k3s_server_ip=<PRIVATE_IP from kube-1> -e k3s_token='<TOKEN from kube-1>'
```

### Verification

From `kube-1`:

```bash
sudo k3s kubectl get nodes -o wide            # all three Ready
sudo k3s kubectl describe node <kube-1 name> | grep -A2 Taints   # control-plane taint present
sudo k3s kubectl -n kube-system get pods      # no traefik/svclb pods
```

### Idempotency

Both plays are safe to re-run:

- `playbooks/server.yml` guards the install with `creates: /usr/local/bin/k3s`.
- `playbooks/agent.yml` guards the install with `creates: /etc/systemd/system/k3s-agent.service` — **not** `/usr/local/bin/k3s-agent`, which doesn't exist; the k3s agent installs the same `/usr/local/bin/k3s` binary as the server and only creates a distinct `k3s-agent.service` systemd unit. Verified live: re-running with the wrong path reported `changed=1` every time; the systemd-unit path correctly reports `changed=0` on a second run.

### Rebuild note

A full rebuild produces a **new** join token each time `playbooks/server.yml` installs k3s fresh on `kube-1` — the token is never stored anywhere (not in this repo, not on disk beyond the instance itself), so it must be re-copied by hand to the agent runs after every rebuild. This keeps the cluster-admin-equivalent token out of Git, matching the "no plaintext secret committed to Git" requirement.

## Layout

- `playbooks/server.yml` — installs k3s on the control plane (`kube-1`), disables the bundled Traefik/servicelb, applies the control-plane taint, prints the join token and private IP.
- `playbooks/agent.yml` — installs k3s and joins the cluster, given `k3s_server_ip` and `k3s_token` as extra-vars.
