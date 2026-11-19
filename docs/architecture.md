# Architecture

## Network

| Resource | Value | Notes |
|---|---|---|
| VPC | `10.20.0.0/16` (`VPC_CIDR`) | Dedicated VPC. DNS support and hostnames enabled. The default VPC is never used or modified. |
| Public subnet | `10.20.0.0/24` | Holds only the NAT gateway. Route: `0.0.0.0/0 -> Internet Gateway`. |
| Private subnet | `10.20.10.0/24` | All three nodes. Route: `0.0.0.0/0 -> NAT gateway`. No public IPs are ever assigned. |
| NAT gateway | In the public subnet, one Elastic IP | Outbound only: apt, container registries, GitHub, SSM. No inbound path to the nodes. |
| Route tables | One per subnet, explicitly associated | The VPC's main route table is left unused. |
| Pod CIDR | `10.244.0.0/16` | Overlay network, not a VPC subnet. Must not overlap the VPC CIDR. |
| Service CIDR | `10.96.0.0/12` | Virtual IPs, internal to the cluster. |

Everything is in **one Availability Zone** to keep the lab cheap and simple; see [production-notes.md](production-notes.md) for the three-AZ design.

## Nodes

| Node | Type | Private IP | Security group | Role |
|---|---|---|---|---|
| `<cluster>-cp` | t3.medium | `10.20.10.10` (fixed) | `CP_SG` | API server, etcd, scheduler, controller-manager |
| `<cluster>-worker1` | t3.medium | DHCP | `WK_SG` | Workloads |
| `<cluster>-worker2` | t3.medium | DHCP | `WK_SG` | Workloads |

The control plane has a fixed IP because it is the cluster endpoint (`controlPlaneEndpoint`) and is baked into the API server certificate. All nodes keep the default AWS hostname (`ip-10-20-10-x.ec2.internal`); the AWS cloud-controller-manager, if you add it later, expects the private DNS name as the node name.

Each instance:

- Ubuntu 24.04 LTS AMI, resolved at launch from Canonical's public SSM parameter
- 30 GB encrypted gp3 root volume
- IMDSv2 required, hop limit 1
- Instance profile with `AmazonSSMManagedInstanceCore` only
- Tags: `Name`, `project=<cluster>`, `kubernetes.io/cluster/<cluster>=owned`

## Software

| Layer | Choice | Where it is configured |
|---|---|---|
| Container runtime | containerd, `SystemdCgroup = true` | `scripts/node/node-userdata.sh` |
| Kubernetes | kubeadm/kubelet/kubectl from `pkgs.k8s.io`, held | `node-userdata.sh`, `K8S_MINOR` in `config.env` |
| Cluster bootstrap | `kubeadm init --config` (v1beta4) | `k8s/kubeadm-config.yaml` |
| Pod networking | Calico via the Tigera operator, VXLAN | `k8s/calico-installation.yaml`, `scripts/node/install-calico.sh` |
| Secret encryption | `aescbc` EncryptionConfiguration, key generated on the node | `scripts/node/cp-init.sh` |
| Kubelet certificates | Serving certs from the cluster CA (`serverTLSBootstrap`) | `kubeadm-config.yaml`, approved by `post-join.sh` |

## Control flow of a build

```
laptop                                     AWS                         nodes
------                                     ---                         -----
01-network.sh      aws ec2 ...  ------->   VPC, subnets, NAT, routes
02-iam.sh          aws iam ...  ------->   role + instance profile
03-security-groups aws ec2 ...  ------->   security groups and rules
04-launch          aws ec2 run-instances ->  3 instances  ---- cloud-init ---> containerd + kube packages
                                                                               (user-data, first boot)
05..08             aws ssm send-command ->   SSM service ---- agent --------> kubeadm init / join / Calico /
                                                                               smoke test (scripts/node/*)
```

The laptop never connects to a node directly. Each node script is base64-encoded into a single command, run as root, and its output returned to the terminal. See [ssm-guide.md](ssm-guide.md).

## State and idempotency

`.state/cluster.env` records every resource ID (`VPC_ID`, `NAT_ID`, `CP_SG`, `CP_ID`, ...). A script creates only what is missing, and `99-teardown.sh` deletes by these IDs and forgets each one only after it is really gone. Lose the file and the scripts no longer know what exists; the resources are tagged `project=<cluster>`, so you can still find them in the console.

## Why a few things are the way they are

- **Calico VXLAN, not native routing:** works on plain EC2 without touching source/destination checks, and needs just one extra UDP port.
- **Typha and VXLAN ports are open between all nodes:** the overlay is node-to-node UDP, invisible to AWS as pod traffic.
- **One shared node role:** simplest for a lab. Production uses separate roles per node type ([production-notes.md](production-notes.md)).
- **Public ECR mirrors in the smoke test:** avoids Docker Hub's anonymous rate limit on the shared NAT address.
