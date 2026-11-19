# Kubernetes on AWS with kubeadm (custom VPC, SSM-only access)

A reproducible build of a **kubeadm Kubernetes cluster on EC2**: 1 control plane + 2 workers in a **custom VPC** (never the default one), with no SSH, no bastion and no public IPs on the nodes. Provision the AWS infrastructure with **Terraform** (recommended) or with plain **AWS CLI scripts**; the Kubernetes bootstrap is shell scripts that run on the nodes through SSM, and every script is safe to re-run.

It is a learning/lab environment built the way you would build production, and each design choice has a documented "what changes in production" note.

```
                        Internet
                           |
                    [Internet Gateway]
                           |
  VPC 10.20.0.0/16         |
  +------------------------+--------------------------------------------+
  |  public subnet 10.20.0.0/24                                          |
  |     [NAT Gateway]  (outbound only; nothing else lives here)          |
  |           ^                                                          |
  |  private subnet 10.20.10.0/24                                        |
  |     +--------------+   +--------------+   +--------------+           |
  |     | control plane|   |   worker-1   |   |   worker-2   |           |
  |     | 10.20.10.10  |   |              |   |              |           |
  |     +--------------+   +--------------+   +--------------+           |
  |       no public IPs, no SSH, no key pairs, IMDSv2 only               |
  +----------------------------------------------------------------------+
                           ^
        You: AWS SSM Session Manager / Run Command (outbound HTTPS from the nodes)
```

| Component | Choice |
|---|---|
| OS | Ubuntu 24.04 LTS (latest Canonical AMI, resolved at launch) |
| Kubernetes | v1.36 via `pkgs.k8s.io` (configurable, packages held) |
| Runtime | containerd, systemd cgroup driver |
| CNI | Calico, VXLAN, via the Tigera operator |
| Node access | AWS Systems Manager (Session Manager and Run Command) only |
| Instances | 3 x t3.medium, encrypted gp3, IMDSv2 required |

## Quick start

**Prerequisites**
- An AWS account and credentials with permission to manage EC2, VPC, IAM and SSM (`aws sts get-caller-identity` works)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (used by the Kubernetes phase for SSM even if Terraform builds the infrastructure)
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) (only needed for `ssm.sh shell` and `forward-api`)
- `bash` (Linux, macOS, or WSL; the scripts have a bash shebang, so run them directly even if your login shell is zsh) and `make` (optional)
- For Option A: [Terraform](https://developer.hashicorp.com/terraform/install) 1.6+ or [OpenTofu](https://opentofu.org) (`make ... TF=tofu`)

Pick **one** way to build the infrastructure. Both give the same result and feed the same phase 2.

**Phase 1, Option A: Terraform (about 5 minutes)**

```bash
make tf-init                         # download the AWS provider
make tf-plan                         # review what will be created
make tf-up                           # apply, then copy the outputs into .state/ for phase 2
make status                          # wait 3-5 minutes until all three show Online
```

Settings live in `terraform/terraform.tfvars` (see `terraform.tfvars.example`). Details: [docs/terraform.md](docs/terraform.md).

**Phase 1, Option B: AWS CLI scripts (about 5 minutes)**

```bash
cp config.env.example config.env     # review region, CIDRs, instance types
make infra                           # = 01-network, 02-iam, 03-security-groups, 04-launch-instances
make status                          # wait 3-5 minutes until all three show Online
```

**Phase 2: Kubernetes (about 10 minutes, configured through SSM; same for both options)**

```bash
make cluster                         # = 05-init-control-plane, 06-install-cni, 07-join-workers, 08-smoke-test
```

**Use the cluster from your laptop** (nothing is exposed; the API is tunnelled through SSM):

```bash
./scripts/ssm.sh kubeconfig          # writes .state/kubeconfig
./scripts/ssm.sh forward-api         # leave running in terminal 1
export KUBECONFIG=$PWD/.state/kubeconfig   # terminal 2
kubectl get nodes
```

**Tear everything down** (stops all charges):

```bash
make tf-destroy                      # Option A (Terraform)
make down                            # Option B (AWS CLI scripts)
```

Each refuses to run on the other's infrastructure, so you cannot delete the wrong thing by mistake. Without `make`, run the numbered scripts in `scripts/` in order (or `terraform -chdir=terraform ...` directly). `make help` lists all targets.

Pod and service CIDRs and the Calico version are cluster settings, not infrastructure: they stay in `config.env` for both options (`make tf-sync` creates it from the example if it is missing).

## Cost

Roughly **US$0.17 per hour (about US$4 per day)** in us-east-1: 3 x t3.medium plus a NAT gateway, excluding data transfer. The NAT gateway is the largest fixed cost, so destroy everything (`make tf-destroy` or `make down`) when you are done.

## Repository layout

```
.
├── README.md
├── LICENSE
├── Makefile                     # make tf-up / infra / cluster / tf-destroy / down / lint
├── config.env.example           # cluster settings; copy to config.env (git-ignored)
├── terraform/                   # Option A: AWS infrastructure as Terraform
│   ├── versions.tf              # Terraform + provider constraints
│   ├── providers.tf             # AWS provider, default tags
│   ├── variables.tf             # all inputs
│   ├── network.tf               # VPC, subnets, IGW, NAT, route tables
│   ├── iam.tf                   # node role + instance profile (SSM)
│   ├── security_groups.tf       # control-plane and worker SGs; rules as a map
│   ├── instances.tf             # 1 control plane + 2 workers
│   ├── outputs.tf               # IDs used by scripts/tf-sync.sh
│   ├── terraform.tfvars.example
│   └── backend.tf.example       # S3 remote state
├── scripts/
│   ├── lib.sh                   # shared helpers: state, idempotent SG rules, SSM Run Command
│   ├── tf-sync.sh               # Option A: copy Terraform outputs into .state/ for phase 2
│   ├── 01-network.sh            # Option B: VPC, subnets, IGW, NAT, route tables
│   ├── 02-iam.sh                # Option B: node role + instance profile (SSM)
│   ├── 03-security-groups.sh    # Option B: control-plane and worker SGs, one rule per line
│   ├── 04-launch-instances.sh   # Option B: 1 control plane + 2 workers
│   ├── 05-init-control-plane.sh # kubeadm init (through SSM)
│   ├── 06-install-cni.sh        # Calico (through SSM)
│   ├── 07-join-workers.sh       # join workers, approve kubelet CSRs, label workers
│   ├── 08-smoke-test.sh         # scheduling, NodePort, DNS, kubectl logs
│   ├── 99-teardown.sh           # Option B: delete everything, in dependency order
│   ├── ssm.sh                   # status | shell | forward-api | kubeconfig | run | script
│   └── node/                    # scripts that run ON the instances (sent via SSM)
│       ├── node-userdata.sh     # cloud-init: swap, sysctl, containerd, kubeadm packages
│       ├── cp-init.sh
│       ├── install-calico.sh
│       ├── join-command.sh
│       ├── worker-join.sh
│       ├── post-join.sh
│       └── smoke-test.sh
├── k8s/                         # manifests and kubeadm config (placeholders filled from config.env)
│   ├── kubeadm-config.yaml
│   ├── calico-installation.yaml
│   └── smoke-test.yaml
├── iam/
│   └── ssm-operator-policy.json # least-privilege policy for the humans who use SSM
└── docs/
    ├── architecture.md          # network, nodes, how the pieces fit
    ├── terraform.md             # Terraform layout, design notes, day-2, production changes
    ├── ssm-guide.md             # Session Manager and Run Command, start to finish
    ├── security-groups.md       # every rule, why it exists, dev vs production
    ├── operations.md            # kubectl access, etcd backup, upgrades, adding nodes
    ├── production-notes.md      # what changes when this becomes production
    └── troubleshooting.md       # errors you may hit and how to fix them
```

## How it works

- **Two layers.** Infrastructure (VPC, IAM, security groups, instances) comes from Terraform or the CLI scripts. The cluster bootstrap (`kubeadm init`, Calico, joins) is always the SSM scripts, because it is one-time and depends on runtime values such as join tokens. `make tf-sync` hands Terraform's outputs to the scripts.
- **State.** The CLI scripts save every created resource ID in `.state/cluster.env` (git-ignored); a script skips what already exists, so if something fails you fix it and run the same script again, and teardown uses the same file. With Terraform the real state is Terraform's, and `.state/cluster.env` is just a copy of the IDs that phase 2 needs.
- **No SSH.** Nodes configure themselves at boot (user-data installs containerd and the Kubernetes packages). Cluster steps (`kubeadm init`, `join`, Calico) are shell scripts in `scripts/node/` that the laptop-side scripts send through **SSM Run Command**. Read [docs/ssm-guide.md](docs/ssm-guide.md) first if SSM is new to you.
- **Idempotent node scripts.** `cp-init.sh` and `worker-join.sh` detect an existing cluster/join and exit cleanly.
- **Configuration.** Terraform: `terraform/terraform.tfvars`. CLI scripts: `config.env`. Pod/service CIDRs and the Calico version: `config.env` in both cases. Nothing is hardcoded in the scripts.

## Security posture (lab)

- Nodes live in a private subnet, no public IPs, no inbound from the internet
- No SSH, no key pairs; sessions are authenticated by IAM and recorded in CloudTrail
- IMDSv2 required with hop limit 1, so pods cannot read the node's IAM credentials
- Encrypted EBS volumes; Kubernetes Secrets encrypted at rest in etcd
- Security groups reference each other (no CIDR rules except the NodePort range from inside the VPC); rule-by-rule explanation in [docs/security-groups.md](docs/security-groups.md)
- Kubelet serving certificates issued by the cluster CA (`serverTLSBootstrap`)
- Kubernetes packages version-held; control-plane taint kept

Not covered here and listed in [docs/production-notes.md](docs/production-notes.md): multi-AZ HA control plane, load-balanced API endpoint, KMS-backed encryption, audit logging, restricted egress, OIDC login, backups, upgrades.

## Documentation

| Doc | Read it when |
|---|---|
| [docs/terraform.md](docs/terraform.md) | You are using the Terraform option, or want its design notes and production changes |
| [docs/ssm-guide.md](docs/ssm-guide.md) | You want to understand or debug how you reach the nodes |
| [docs/security-groups.md](docs/security-groups.md) | You want to know why each port is open (or closed) |
| [docs/operations.md](docs/operations.md) | The cluster is up and you want to use, back up or upgrade it |
| [docs/production-notes.md](docs/production-notes.md) | You are turning this into a production design |
| [docs/troubleshooting.md](docs/troubleshooting.md) | A script failed |
| [docs/architecture.md](docs/architecture.md) | You want the full picture |

## Development

```bash
make lint          # bash -n + shellcheck on every script
make tf-validate   # terraform fmt -check + validate (run `make tf-init` first)
```

Never commit `config.env`, `.state/` or any kubeconfig: they contain account details and cluster-admin credentials. They are in `.gitignore` already.

## License

MIT, see [LICENSE](LICENSE).
