# Terraform guide

The `terraform/` directory builds the same AWS infrastructure as the CLI scripts (`scripts/01` to `04`): custom VPC, NAT, IAM role, security groups and three instances. The Kubernetes steps (`kubeadm init`, Calico, joins) are **not** Terraform's job and stay as the SSM scripts, which work unchanged on top of either path.

## Two layers, on purpose

| Layer | Tool | What it owns | Why |
|---|---|---|---|
| Infrastructure | Terraform | VPC, subnets, NAT, route tables, IAM, security groups, EC2 instances | Declarative, has state, shows a plan, can destroy cleanly |
| Cluster bootstrap | `scripts/05` to `08` over SSM | `kubeadm init`, Calico, join, smoke test | One-time, imperative, depends on runtime values (join tokens, certificate hashes) that do not belong in Terraform state |

`make tf-sync` is the bridge: it copies the Terraform outputs (instance IDs, security group IDs, region, control-plane IP) into `.state/cluster.env`, which is what the SSM scripts read.

## Quick start

Prerequisites: Terraform 1.6+ (or [OpenTofu](https://opentofu.org), use `TF=tofu`), AWS credentials (`aws sts get-caller-identity` works), AWS CLI v2 and the Session Manager plugin for phase 2 (see [ssm-guide.md](ssm-guide.md)).

```bash
make tf-init                         # downloads the AWS provider (writes terraform/.terraform.lock.hcl)
make tf-plan                         # read it: about 40 resources to add
make tf-up                           # apply (asks for confirmation), then sync outputs into .state/
make status                          # wait 3-5 minutes until all three nodes are Online
make cluster                         # kubeadm init, Calico, join workers, smoke test
```

Tear down:

```bash
make tf-destroy                      # Terraform deletes everything it created, then .state/ is cleared
```

Customise by copying `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars` (git-ignored), or pass `-var` flags through `TF_ARGS`. Skip the confirmation prompt with `make tf-up TF_ARGS=-auto-approve`.

> Commit `terraform/.terraform.lock.hcl` after the first `make tf-init`. It pins the exact provider build, so everyone (and CI) gets the same one. To also support teammates on other platforms run `terraform -chdir=terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64`.

## File map

| File | Contents |
|---|---|
| `versions.tf` | Terraform and provider version constraints (`aws ~> 6.0`) |
| `providers.tf` | AWS provider, `default_tags` (`project`, `managed-by`) |
| `variables.tf` | Every input, with descriptions and validation |
| `network.tf` | VPC, subnets, internet gateway, NAT gateway + EIP, route tables, locked-down default security group |
| `iam.tf` | Node role (`AmazonSSMManagedInstanceCore` only) and instance profile |
| `security_groups.tf` | Control-plane and worker groups; every rule is an entry in a map |
| `instances.tf` | Ubuntu 24.04 AMI lookup, control plane, two workers |
| `outputs.tf` | IDs consumed by `scripts/tf-sync.sh`, plus `next_steps` |
| `terraform.tfvars.example` | Every variable at its default value |
| `backend.tf.example` | S3 remote state with native locking |

## Inputs

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `az_suffix` | `a` | Single AZ in the lab |
| `cluster` | `k8s-lab` | Prefix of every name and the `project` tag; validated |
| `vpc_cidr` | `10.20.0.0/16` | |
| `public_subnet_cidr` | `10.20.0.0/24` | NAT gateway only |
| `private_subnet_cidr` | `10.20.10.0/24` | All nodes |
| `cp_ip` | `10.20.10.10` | Must be inside the private subnet and not one of its first four addresses |
| `cp_instance_type`, `worker_instance_type` | `t3.medium` | kubeadm needs at least 2 vCPU and 2 GB |
| `root_volume_gb` | `30` | Encrypted gp3 |
| `kms_key_id` | `null` | Customer-managed key for EBS; `null` = AWS-managed key |
| `ami_id` | `""` | Empty = latest Canonical Ubuntu 24.04; set to pin |
| `k8s_minor` | `v1.36` | Kubernetes minor the nodes install at first boot |

Pod and service CIDRs, and the Calico version, are cluster settings, not infrastructure: they stay in `config.env` and are read by `scripts/05` and `06`.

## Design notes

**Security group rules are data, not copy-paste.** `security_groups.tf` keeps the rules in two maps (`cp_ingress`, `worker_ingress`) and creates them with one `for_each` per group. To open a port, add an entry; its key becomes its address in the state, so do not rename keys casually. Rules are separate `aws_vpc_security_group_*_rule` resources, not inline blocks, which avoids the dependency cycle of two groups that reference each other. Each rule is explained in [security-groups.md](security-groups.md).

**Egress is declared explicitly.** Terraform removes the default allow-all egress rule of a security group it creates. Without the explicit rules in `security_groups.tf` the nodes could not reach apt, registries or SSM, and would never come Online.

**Nodes are protected from accidental replacement.** `instances.tf` sets `ignore_changes = [ami, user_data]`. Otherwise a new Ubuntu AMI published next month, or an edit to the user-data script, would make `terraform plan` propose destroying and recreating the control plane. To roll a node onto a new image on purpose: `terraform -chdir=terraform apply -replace='aws_instance.worker["worker1"]'` (drain it first; see [operations.md](operations.md)). Replacing the control plane destroys etcd: take a snapshot first, and in this single-node design treat it as a rebuild.

**One user-data script for both paths.** The instances read `scripts/node/node-userdata.sh` with `file()` and replace only the `__K8S_MINOR__` placeholder. (`templatefile()` would try to interpret the script's own `${...}` shell variables.)

**Network ordering.** The instances `depends_on` the private route to the NAT gateway and the egress rules, because their user-data downloads packages immediately at first boot.

**The VPC default security group is emptied** (`aws_default_security_group`), so nothing can silently depend on it.

**Tags.** `default_tags` adds `project=<cluster>` to everything; the SSM operator policy in `iam/` matches on that tag. Instances also carry `kubernetes.io/cluster/<cluster>=owned`, which the AWS cloud-controller-manager needs if you add it later.

## State

Local state (`terraform/terraform.tfstate`) is fine for a personal lab and is git-ignored. It holds resource IDs, not secrets (the etcd encryption key is generated on the control plane and never passes through Terraform). For a shared environment use a remote backend: copy `backend.tf.example` to `backend.tf`, create the bucket (versioning on, encryption on, public access blocked), and run `terraform init -migrate-state`.

## Using Terraform and the CLI scripts together

Pick one provisioning path per environment. `tf-sync.sh` refuses to run if `.state/` describes CLI-created resources, and `99-teardown.sh` refuses to run on Terraform-managed ones (it would leave Terraform's state wrong). To move from the CLI path to Terraform: `./scripts/99-teardown.sh`, then `make tf-up`. There is no import step, because the point is a clean, reviewable rebuild.

## Day-2 changes

| Change | How |
|---|---|
| Open or close a port | Edit the map in `security_groups.tf`, `make tf-plan`, `make tf-apply`. No node restarts. |
| Change instance type | Edit the variable and apply. AWS stops and starts the instance (not a replacement); drain a worker first, and expect the API to be down briefly for the control plane. |
| Change CIDRs or `cp_ip` | Forces replacement of the VPC or nodes: rebuild the cluster. |
| New `k8s_minor` | Affects new nodes only (user-data is ignored on existing ones). Upgrade existing nodes with kubeadm ([operations.md](operations.md#upgrade-kubernetes)). |
| Add a third worker | Add `"worker3"` to `local.workers`, add an output for it, extend `tf-sync.sh` and the scripts that assume two workers (`07`, `ssm.sh`). The scripts are intentionally fixed at 1 + 2 to stay readable; production uses an Auto Scaling Group (below). |
| Check for drift | `terraform plan` shows anything changed by hand in the console. |

## Destroying cleanly

`make tf-destroy` deletes instances, NAT, subnets, security groups, VPC and IAM in dependency order. One trap: **if you added anything that creates AWS resources from inside the cluster** (an AWS Load Balancer Controller, or `Service type=LoadBalancer` with the cloud-controller-manager), delete those Services/Ingresses first and wait for the load balancers to disappear. Terraform does not know about them, and they keep network interfaces and security groups alive, so the VPC deletion fails with `DependencyViolation`.

## Production changes for the Terraform code

| Area | Lab | Production |
|---|---|---|
| Structure | Flat root module | Modules (`network`, `iam`, `cluster-nodes`), one root per environment, or workspaces; versions pinned per environment |
| State | Local | Remote (S3 with locking, versioned, KMS-encrypted), restricted IAM, separate state per environment and per layer (network vs nodes) |
| Execution | Laptop | CI/CD: `plan` on pull request, reviewed `apply` on merge, using short-lived credentials through OIDC federation, no long-lived keys |
| Checks | `fmt`, `validate` | Add `tflint`, a policy scanner (Checkov or Trivy config), `pre-commit` hooks, and cost estimation on the plan |
| Compute | Three `aws_instance` resources | Launch templates + Auto Scaling Groups per AZ for workers; three control-plane nodes (ASG of fixed size or three instances) behind an internal NLB; golden AMI from Image Builder or Packer, so user-data only joins the cluster |
| AZs | One | A map of AZ -> subnets with `for_each`: three private subnets, three public subnets, one NAT gateway per AZ |
| Network | NAT only | Add VPC endpoints for `ssm`, `ssmmessages`, `ec2messages`, `ecr`, `sts`, `logs` and S3; flow logs |
| IAM | One shared role | Separate control-plane and worker roles, least-privilege policies for the cloud-controller-manager, EBS CSI driver and etcd backup bucket |
| Security groups | Allow-all egress, NodePort from VPC CIDR | Restricted egress; a load-balancer security group as the NodePort source ([security-groups.md](security-groups.md#8-production-layout)) |
| Drift | Manual `plan` | Scheduled `plan` in CI that alerts on drift |
| Protection | None | `prevent_destroy` on state buckets and the control plane's data volumes; deletion protection on load balancers |

More cluster-level changes (OIDC login, KMS-backed secrets, audit logging, backups) are in [production-notes.md](production-notes.md).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `No valid credential sources found` / `ExpiredToken` | AWS credentials missing or expired | `aws sts get-caller-identity`; export credentials or set `AWS_PROFILE` |
| `Error: Failed to query available provider packages` | No access to `registry.terraform.io` | Check network/proxy; or use OpenTofu (`TF=tofu`) |
| `Unsupported argument` / `Invalid provider version` | Provider major changed | The code targets AWS provider 6.x (`~> 6.0`); run `make tf-init` again, or use `terraform init -upgrade` after reading the changelog |
| `InvalidParameterValue: Address 10.20.10.x is not valid for this subnet` | `cp_ip` outside the private subnet, or in its reserved first four addresses | Change `cp_ip` or `private_subnet_cidr` |
| `VpcLimitExceeded` / `AddressLimitExceeded` | Regional quotas (5 VPCs, 5 Elastic IPs) | Delete unused ones or request an increase |
| `Error acquiring the state lock` | Another run is active, or a crashed run left a lock | Wait; if you are sure nothing is running, `terraform force-unlock <ID>` |
| Plan wants to replace the nodes | You removed `ignore_changes`, or changed a CIDR / `cp_ip` | Restore the lifecycle block, or accept a rebuild |
| `make tf-sync`: `No Terraform outputs found` | `apply` has not finished, or you are in a different working copy | Run `make tf-apply`; outputs live in `terraform/terraform.tfstate` |
| `make tf-sync`: `describes resources created by the AWS CLI scripts` | `.state/` left over from the CLI path | `./scripts/99-teardown.sh` first (or delete `.state/` if those resources are already gone) |
| Nodes never show Online in `make status` | No route/egress, or instance profile problem | See the table in [ssm-guide.md](ssm-guide.md#8-troubleshooting); `terraform state list \| grep -E 'route|egress'` should show the NAT route and both egress rules |
| `DependencyViolation` during destroy | Load balancers or ENIs created from inside the cluster | See "Destroying cleanly" above |
