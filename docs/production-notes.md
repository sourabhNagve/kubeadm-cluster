# From lab to production

This repo is a lab built with production habits. This document lists what you change when the cluster has to survive failures, audits and growth. Each section says what the lab does, what production does, and why.

## Summary

| Area | Lab (this repo) | Production |
|---|---|---|
| Control plane | 1 node, endpoint is an IP | 3 nodes in 3 AZs behind an internal NLB; endpoint is a DNS name chosen **before** `kubeadm init` |
| Networking | 1 AZ, 1 NAT gateway | 3 AZs, a NAT gateway per AZ, VPC endpoints, flow logs |
| Nodes | Hand-launched t3.medium | Golden AMI + launch templates + Auto Scaling Groups; non-burstable instance types; dedicated etcd volume |
| Access | SSM, `admin.conf` | SSM/VPN + OIDC SSO + RBAC groups; admin cert in a vault; session logging on |
| Secrets | `aescbc` key on the node's disk | KMS provider and/or an external secrets manager |
| IAM | One shared node role, SSM only | Separate CP/worker roles; cloud-controller-manager and CSI driver permissions; no node role for pods |
| Policy | Defaults | Pod Security Admission (restricted), default-deny NetworkPolicy, admission policy (Kyverno/Gatekeeper) |
| Observability | `kubectl` | Prometheus/Grafana, metrics-server, central logs, API audit logs, alerts on etcd/API latency |
| Cloud integration | None | AWS cloud-controller-manager, EBS CSI driver, AWS Load Balancer Controller, autoscaling |
| Backup / DR | Manual etcd snapshot | Automated snapshots to S3 (cross-region), Velero, tested restore runbook |
| Upgrades | Manual | One minor at a time, staging first, PodDisruptionBudgets, node replacement |
| Egress | Allow-all | Restricted to VPC endpoints and known destinations |
| IaC | AWS CLI scripts | Versioned IaC (CloudFormation / CDK / Terraform) through CI/CD with review |

## 1. Network

- **Three AZs.** Three private subnets (nodes), three public subnets (load balancers, NAT), **one NAT gateway per AZ** with a private route table per AZ, so losing an AZ does not take out egress for the others.
- **CIDR planning.** Size for growth (for example a /16 VPC and /20 or larger private subnets). Avoid overlap with other VPCs, on-prem ranges and the pod/service CIDRs, since peering, Transit Gateway and VPN need non-overlapping addresses.
- **VPC endpoints.** S3 (gateway); `ssm`, `ssmmessages`, `ec2messages`, `ecr.api`, `ecr.dkr`, `sts`, `logs` (interface). Traffic stays inside AWS, costs less than NAT data processing, and works without internet egress.
- **Visibility.** VPC Flow Logs to CloudWatch or S3. Network ACLs as a coarse second layer if your policy requires it.
- **Account structure.** A dedicated workload account in AWS Organizations, SCP guardrails, and no workloads in the management account.

## 2. Security groups

Full layout in [security-groups.md](security-groups.md#8-production-layout). In short:

- Restrict **egress** (HTTPS to the endpoint SG, intra-cluster ports only).
- API behind an **internal NLB**; admin access through VPN / Direct Connect / SSM.
- A dedicated load-balancer SG for public traffic; nodes accept NodePort/target traffic only from that SG, not the whole VPC.
- Rules reviewed as code; AWS Config / Security Hub flag any `0.0.0.0/0` ingress.

## 3. Control plane and the API endpoint

- **`controlPlaneEndpoint` must be a stable DNS name for an internal NLB** (for example `k8s-api.prod.internal:6443`), set at `kubeadm init`. An IP endpoint (as in the lab) cannot become highly available without re-issuing certificates and reconfiguring every node.
- **Three control-plane nodes**: `kubeadm init --upload-certs`, then `kubeadm join --control-plane` on the others. etcd needs an odd member count for quorum. Add the new nodes to the etcd rule (already covered by `CP_SG -> CP_SG`).
- **etcd storage.** A dedicated gp3/io2 volume (for example 3,000+ IOPS) mounted at `/var/lib/etcd`, separate from the root disk. etcd latency is the cluster's latency.
- **API hardening.** Audit logging (`--audit-policy-file`, `--audit-log-path`, rotation, shipped to CloudWatch or a SIEM); OIDC flags for human logins; Pod Security Admission configured cluster-wide; pin `kubernetesVersion` explicitly and keep the kubeadm config in version control.

## 4. Encryption and secrets

- Replace the static `aescbc` key with the **AWS KMS encryption provider** so the key never sits on disk, and back up key material and policy deliberately.
- Keep application secrets in AWS Secrets Manager / Parameter Store with the External Secrets Operator or the Secrets Store CSI driver, so the cluster is a consumer and not the system of record.
- Encrypt EBS with a customer-managed KMS key; enable default EBS encryption in the account.

## 5. Nodes

- **Golden AMI**: build with EC2 Image Builder or Packer with OS patches, containerd, pinned kube packages, CIS hardening and the SSM and CloudWatch agents preinstalled. Boots become fast, deterministic and independent of the public internet. User-data is then only "join the cluster".
- **Launch templates + Auto Scaling Groups** (one per AZ for workers) so nodes self-heal and scale, with the Cluster Autoscaler or a similar tool. Control-plane nodes can also be in fixed-size ASGs with stable ENIs/volumes for etcd.
- **Instance types.** Non-burstable (m6i/m7i or similar). t3 credits run out under sustained load and cause hard-to-diagnose latency.
- **Node groups.** Separate groups (general, memory, spot, GPU) with labels and taints.
- **Mirror** images and packages in ECR and an internal apt mirror instead of the public internet.
- **CIS benchmark.** Run `kube-bench` against nodes and the control plane.

## 6. IAM and identity

- **Separate roles for control plane and workers**, each with only what it needs: the cloud-controller-manager and EBS CSI driver need specific EC2/ELB/EBS permissions (use the AWS-published policies); the control plane gets scoped S3 write for etcd backups; workers get ECR pull (`AmazonEC2ContainerRegistryReadOnly`).
- **Do not give pods the node's role.** IMDSv2 with hop limit 1 already blocks it. For per-workload AWS access on self-managed Kubernetes, use OIDC federation with a self-hosted issuer (IRSA-style) or a workload-identity tool.
- Permission boundaries and SCPs at the organisation level.
- **Humans:** IAM Identity Center for AWS access; OIDC for Kubernetes; no long-lived keys.

## 7. Observability and operations

- **Metrics:** metrics-server, Prometheus and Grafana (or a managed equivalent), node exporter, kube-state-metrics. Alert on etcd fsync latency and DB size, API server latency and errors, node pressure, certificate expiry, and pods stuck pending.
- **Logs:** a log shipper to CloudWatch/OpenSearch/your platform; API audit logs; SSM session logs.
- **Certificates:** monitor expiry (`kubeadm certs check-expiration`), upgrade at least yearly, and auto-approve kubelet serving CSRs with a controller such as `kubelet-csr-approver` that validates node identity and IP instead of blanket approval.
- **Cloud integration:** install the AWS cloud-controller-manager (`--cloud-provider=external` on the kubelet, API server and controller-manager, through `extraArgs` / `kubeletExtraArgs`) so nodes get `providerID` and zone labels and `Service type=LoadBalancer` creates NLBs. The `kubernetes.io/cluster/<name>=owned` tag the repo already puts on instances is part of what it needs; also tag subnets and security groups.
- **Storage and ingress:** EBS CSI driver for persistent volumes; AWS Load Balancer Controller for ALB/NLB.

## 8. Backup and disaster recovery

- **etcd snapshots** every 15-60 minutes, to a versioned, encrypted S3 bucket with cross-region replication and lifecycle rules; alert on missed backups; back up `/etc/kubernetes/pki` and the encryption configuration.
- **Velero** with EBS snapshots for namespaces and volumes.
- **Restore rehearsal** on a scratch cluster on a schedule. A backup that has never been restored is a hypothesis.
- Define RTO/RPO and document the rebuild order (network -> control plane -> add-ons -> workloads).

## 9. Upgrades and patching

- One minor version at a time; staging before production; read the release notes for removed APIs.
- PodDisruptionBudgets on important workloads and enough replicas to survive a node drain.
- Prefer **replacing** nodes (new AMI) over in-place upgrades.
- **OS patching** with SSM Patch Manager in maintenance windows, or by replacing nodes from a patched AMI.
- Track Calico/Cilium, containerd, and add-on versions in the same upgrade plan.

## 10. Workload security

- **Pod Security Admission** at `restricted` for application namespaces (this repo's smoke test namespace uses `baseline` because stock nginx runs as root).
- **NetworkPolicy** default-deny per namespace, then explicit allows. Calico also offers GlobalNetworkPolicy and host-endpoint policy. Consider Cilium (eBPF, Hubble) for richer visibility, and WireGuard for pod-to-pod encryption if required.
- **Admission policy** (Kyverno or OPA Gatekeeper): required labels, no `latest` tags, only trusted registries, no privileged pods.
- **Images:** scan in CI, sign (cosign), and admit only signed images from your registry.
- **RBAC:** least privilege, groups from the IdP, no `cluster-admin` for applications.

## 11. Infrastructure as code and delivery

AWS CLI scripts are good for learning and for understanding exactly what exists. For production, express the same resources as versioned IaC (CloudFormation, CDK or Terraform), apply them through CI/CD with plan review, enforce policy checks, and keep the cluster definition (kubeadm config, add-on versions, manifests) in Git with GitOps (Argo CD or Flux) for workloads.

## Production checklist

- [ ] 3 AZs, 3 control planes behind an internal NLB with a DNS endpoint
- [ ] NAT per AZ + VPC endpoints + flow logs
- [ ] Golden AMI, launch templates, ASGs, non-burstable instances
- [ ] Dedicated etcd volume, automated snapshots to S3, restore rehearsed
- [ ] KMS-backed secret encryption, audit logging enabled and shipped
- [ ] OIDC login + RBAC groups; admin cert in a vault; SSM session logging on
- [ ] Separate node roles; cloud-controller-manager, EBS CSI, LB controller installed
- [ ] Restricted egress; default-deny NetworkPolicy; Pod Security `restricted`
- [ ] Monitoring and alerting (etcd, API, nodes, certificates)
- [ ] Upgrade and patch runbooks, PDBs, staging environment
- [ ] Everything in version-controlled IaC with review
