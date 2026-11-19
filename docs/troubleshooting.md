# Troubleshooting

Scripts are safe to re-run: fix the cause, then run the same script again. For SSM-specific problems (nodes not Online, plugin errors, access denied) see the table in [ssm-guide.md](ssm-guide.md#8-troubleshooting).

## Before anything else

```bash
aws sts get-caller-identity           # right account and credentials?
echo "$AWS_REGION"                    # the scripts export it from config.env; check config.env too
cat .state/cluster.env                # which resources does the repo think exist?
./scripts/ssm.sh status               # are the nodes Online?
```

## Phase 1: AWS infrastructure (AWS CLI scripts)

Using Terraform instead? Its errors (credentials, provider download, state locks, plans that want to replace nodes) are in [terraform.md](terraform.md#troubleshooting). The AWS-side causes below (quotas, IAM propagation, bad `CP_IP`) apply to both.

| Symptom | Cause | Fix |
|---|---|---|
| `Missing .../config.env` | First run | `cp config.env.example config.env` |
| `AWS CLI v2 is required` | `aws` not installed or not on `PATH` | Install AWS CLI v2 |
| `VpcLimitExceeded` | 5 VPCs per region by default | Delete an unused VPC or request a limit increase |
| `AddressLimitExceeded` | Elastic IP limit (5 per region) | Release an unused Elastic IP |
| `UnauthorizedOperation` / `AccessDenied` | Missing IAM permission | Add the permission named in the error; for IAM steps you need `iam:CreateRole`, `CreateInstanceProfile`, `AttachRolePolicy`, `PassRole` |
| `InvalidParameterValue ... Invalid IAM Instance Profile name` at launch | IAM propagation delay | Wait 30 seconds, run `04-launch-instances.sh` again |
| `InvalidIPAddress.InUse` / `Address ... is not in subnet` | `CP_IP` outside `PRIV_CIDR`, or one of the first 4 addresses of the subnet, which AWS reserves | Pick a free address inside `PRIV_CIDR` (for example `.10`) |
| `InvalidGroup.Duplicate` | A group with this name exists from an earlier run whose state was lost | Delete it in the console, or restore `.state/cluster.env`, then re-run |
| `InvalidPermission.Duplicate` | Rule already exists | Not an error: the scripts report it as `exists` and continue |
| `Unsupported instance type` / capacity error | Instance type not available in that AZ | Change `INSTANCE_TYPE_*` or `AZ_SUFFIX` in `config.env`, and delete the instances' state lines if some were created |

## Phase 2: Kubernetes

| Symptom | Cause | Fix |
|---|---|---|
| `send-command failed ... Is the instance Online` | SSM registration not finished | Wait; `./scripts/ssm.sh status` until all three are `Online` |
| `Node preparation did not complete` | User-data failed (usually no internet from the node) | `ssm.sh run cp "tail -50 /var/log/k8s-node-prep.log"`; check the private route table points to the NAT gateway and the NAT is `available` |
| `kubeadm init` preflight errors about swap/CPU/memory | Instance too small, or user-data did not run | Use at least 2 vCPU and 2 GB (t3.medium is the tested size); check the prep log |
| `kubeadm init` hangs at "waiting for the kubelet" | containerd cgroup driver mismatch, or image pulls blocked | `ssm.sh run cp "journalctl -u kubelet -n 40 --no-pager"`; verify `SystemdCgroup = true` in `/etc/containerd/config.toml` |
| Calico step: `Could not determine the latest Calico release` | GitHub API rate limit on the shared NAT address | Set `CALICO_VERSION` in `config.env` (for example `v3.31.0`) and run `06-install-cni.sh` again |
| Calico step: `no matches for kind "Installation"` | CRD not registered yet | Run `06-install-cni.sh` again (the script waits for the CRD; a transient API error can still interrupt it) |
| Nodes stay `NotReady` | CNI not running on that node, or VXLAN blocked | `ssm.sh run cp "kubectl -n calico-system get pods -o wide"`; confirm udp 4789 and tcp 5473 rules exist between the security groups (`03-security-groups.sh` output) |
| Pods on different nodes cannot talk, but nodes are `Ready` | udp 4789 blocked | Re-run `03-security-groups.sh`; verify both groups allow 4789 from both groups |
| Join: `couldn't validate the identity of the API server` / timeout | tcp 6443 blocked from the worker, or the token expired | Check rule C1; tokens last 1 hour: just re-run `07-join-workers.sh` |
| Join: `already joined` message | The node joined earlier | Expected. To rejoin a node, run `kubeadm reset -f` on it first (and `kubectl delete node` on the control plane) |
| `kubectl logs/exec` fails with `tls: internal error` or a certificate error | Kubelet serving CSR not approved | `make approve` (re-runs `post-join.sh`) |
| `kubectl top` shows `Metrics API not available` | metrics-server is not installed by this repo | Install it; its pods can already scrape kubelets (rules C5, W2). With `serverTLSBootstrap` you do not need `--kubelet-insecure-tls` once CSRs are approved |
| Smoke test: NodePort curl times out | Rule W5, or the service/pods are not ready | `ssm.sh run cp "kubectl -n smoke-test get pods,svc -o wide"`; confirm `03-security-groups.sh` created the NodePort rule |
| Smoke test: image pull errors | No egress to the registry | Check NAT/route; the test uses `public.ecr.aws` images |
| `Remote command finished with status: TimedOut` / `InProgress` | The step takes longer than about 10 minutes | Slow image pulls or a stuck step; inspect with `aws ssm list-command-invocations --command-id <id> --details`, fix the cause, re-run the script |

## Teardown

| Symptom | Fix |
|---|---|
| `DependencyViolation` on subnet, security group or VPC | AWS releases network interfaces a minute or two after the NAT gateway and instances are gone. Wait and run `./scripts/99-teardown.sh` again; it retries only what is left |
| `InvalidIPAddress.InUse` on releasing the Elastic IP | The NAT gateway is still releasing it. Same: wait and re-run |
| `.state/cluster.env` was deleted but resources still exist | Find them by the tag `project=<cluster>` in the EC2/VPC console (Tag Editor lists them across services) and delete them in this order: instances, NAT gateway, Elastic IP, subnets, route tables, security groups, internet gateway, VPC, then the IAM profile and role |

## Getting a clean slate

```bash
./scripts/99-teardown.sh --yes
rm -rf .state
```

## Useful diagnostics on a node

```bash
./scripts/ssm.sh run cp "journalctl -u kubelet -n 50 --no-pager"
./scripts/ssm.sh run cp "crictl ps -a | head -20"
./scripts/ssm.sh run cp "kubectl get events -A --sort-by=.lastTimestamp | tail -20"
./scripts/ssm.sh run worker1 "tail -50 /var/log/k8s-node-prep.log"
./scripts/ssm.sh run worker1 "systemctl status containerd kubelet --no-pager | head -20"
```
