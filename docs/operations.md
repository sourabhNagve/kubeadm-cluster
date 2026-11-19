# Operations

Day-2 tasks for the lab cluster, with a note on how each changes in production. Commands that run on the control plane use `./scripts/ssm.sh run cp "..."` or an interactive `./scripts/ssm.sh shell cp` followed by `sudo -i`.

## Access the cluster

| Where | How |
|---|---|
| On the control plane | `ssm.sh shell cp`, then `sudo -i`; kubectl is configured for root |
| From your laptop | `ssm.sh kubeconfig`, `ssm.sh forward-api`, then `export KUBECONFIG=$PWD/.state/kubeconfig` (details in [ssm-guide.md](ssm-guide.md)) |
| One-off | `ssm.sh run cp "kubectl get nodes -o wide"` |

**Production:** people authenticate with OIDC (your IdP) and get RBAC through groups. The `admin.conf` certificate is a break-glass credential kept in a vault, not a daily login.

## Check cluster health

```bash
./scripts/ssm.sh run cp "kubectl get nodes -o wide"
./scripts/ssm.sh run cp "kubectl get pods -A"
./scripts/ssm.sh run cp "kubectl get --raw='/readyz?verbose' | tail -5"
./scripts/ssm.sh run cp "kubeadm certs check-expiration"
```

kubeadm certificates are valid for **one year** and are renewed automatically on `kubeadm upgrade`. If you never upgrade, renew them with `kubeadm certs renew all` and restart the control-plane static pods.

## Back up etcd

etcd holds all cluster state. Take a snapshot (on the control plane, as root):

```bash
apt-get install -y etcd-client
mkdir -p /var/backups
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert   /etc/kubernetes/pki/etcd/server.crt \
  --key    /etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/backups/etcd-$(date +%F-%H%M).db
ETCDCTL_API=3 etcdctl snapshot status /var/backups/etcd-*.db --write-out=table
```

Also keep `/etc/kubernetes/pki/` and `/etc/kubernetes/enc/enc.yaml`. **Without the encryption key, a restored snapshot cannot decrypt its Secrets.**

**Production:** snapshot every 15-60 minutes from a timer or CronJob, upload to a versioned, encrypted S3 bucket (replicated to a second region, lifecycle rules), alert on missed backups, and **rehearse a restore** on a scratch cluster. Add Velero for namespaced resources and persistent volumes.

## Rotate the join token

Join tokens expire after 24 hours by default; the repo creates 1-hour tokens. List and delete leftovers:

```bash
./scripts/ssm.sh run cp "kubeadm token list"
./scripts/ssm.sh run cp "kubeadm token delete <token-id>"
```

## Add another worker

1. Launch an instance the same way as the existing workers (same subnet, `WK_SG`, instance profile, rendered `.state/node-userdata.sh` as user-data), or add a `W3_ID` block to `04-launch-instances.sh`.
2. Wait until it is `Online` in `ssm.sh status` and cloud-init has finished.
3. Join it: get a join command with `ssm.sh script cp scripts/node/join-command.sh`, then `ssm.sh script <instance-id> scripts/node/worker-join.sh <endpoint> <token> <ca-hash>`.
4. Approve its kubelet CSR: `make approve`.

**Production:** workers come from an Auto Scaling Group with a launch template; the join happens in user-data using a token fetched from Secrets Manager / Parameter Store, and a controller auto-approves kubelet serving CSRs.

## Remove a worker

```bash
./scripts/ssm.sh run cp "kubectl drain <node> --ignore-daemonsets --delete-emptydir-data"
./scripts/ssm.sh run cp "kubectl delete node <node>"
```

then terminate the instance.

## Upgrade Kubernetes

Upgrade **one minor version at a time** (1.36 -> 1.37, never skip), control plane first, then workers. Never run an upgrade on a cluster you cannot restore: take an etcd snapshot first.

Control plane:

```bash
# 1. Point the apt repo at the next minor and unhold the packages
sed -i 's/v1.36/v1.37/' /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-mark unhold kubeadm && apt-get install -y kubeadm && apt-mark hold kubeadm
# 2. Check, then apply
kubeadm upgrade plan
kubeadm upgrade apply v1.37.x          # use the exact patch version from `plan`
# 3. Upgrade kubelet and kubectl
apt-mark unhold kubelet kubectl && apt-get install -y kubelet kubectl && apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet
```

Each worker, one at a time:

```bash
kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data     # from the control plane
# on the worker: same apt steps as above for kubeadm, then:
kubeadm upgrade node
# unhold/install/hold kubelet kubectl, restart kubelet
kubectl uncordon <worker>                                              # from the control plane
```

Also set `K8S_MINOR` in `config.env` so **new** nodes install the matching version, and upgrade Calico per its own release notes.

**Production:** staging first; PodDisruptionBudgets on every important workload; with three control planes upgrade them sequentially (`kubeadm upgrade apply` on the first, `kubeadm upgrade node` on the others); prefer replacing worker nodes with a new AMI instead of in-place upgrades.

## OS patching

Ubuntu may apply security updates automatically, but kernel updates need a reboot. In the lab, reboot nodes one at a time (drain first). In production use SSM Patch Manager with maintenance windows, or replace nodes from a freshly baked AMI.

## Cost control

- `make down` removes everything; the NAT gateway is the largest fixed cost.
- To pause for a few hours without destroying: stop the three instances. The NAT gateway still bills; for longer pauses, tear down and rebuild (about 15 minutes).
- Tag-based billing: every resource carries `project=<cluster>`. Activate it as a cost allocation tag to see this cluster's cost separately.
