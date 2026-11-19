# Security groups explained

Every rule created by [`scripts/03-security-groups.sh`](../scripts/03-security-groups.sh), what it is for, why it is that way in the lab, and what changes in production.

## 1. How AWS security groups behave

- **Stateful.** If a connection is allowed in, the reply is allowed out automatically.
- **Allow-only.** There are no deny rules. Anything not explicitly allowed is dropped.
- **A source can be another security group.** `source = WK_SG` means "any instance wearing WK_SG". The rule keeps working when IPs change or nodes are replaced, which is why this repo uses SG references instead of IP ranges.
- **Rules are evaluated on the receiving instance.** Traffic from A to B needs an *inbound* rule on B's group.
- **Not filtered by security groups:** traffic to the VPC DNS resolver and the instance metadata service.
- **Default egress is allow-all** on a new group. This repo leaves egress open in the lab (section 6).
- **Traffic from an instance to its own private IP never leaves the instance**, so a rule whose source is the instance's own group has no effect with a single node of that type. This matters for the `CP_SG -> CP_SG` rules below.

## 2. Who talks to whom

| Flow | Port | Purpose |
|---|---|---|
| worker -> control plane | tcp 6443 | kubelet, kube-proxy, Calico and any pod talking to the API server |
| control plane -> worker | tcp 10250 | API server calling the kubelet (`kubectl logs`, `exec`, `port-forward`) |
| any node <-> any node | udp 4789 | Calico VXLAN: pod-to-pod traffic between nodes, wrapped in UDP |
| any node <-> any node | tcp 5473 | Calico Typha (relays API data to the `calico-node` agents) |
| control plane <-> control plane | tcp 2379-2380 | etcd client and peer traffic |
| scrapers on workers -> every kubelet | tcp 10250 | metrics-server, Prometheus |
| load balancer / VPC -> worker | tcp 30000-32767 | NodePort services |
| you -> nodes | none | The SSM agent connects outbound, so there is no inbound rule |

## 3. Control-plane security group (`CP_SG`), inbound

| # | Rule | Source | Why |
|---|---|---|---|
| C1 | tcp 6443 | `WK_SG` | Workers (and pods, which leave the node with the node's IP because Calico `natOutgoing: Enabled` rewrites the source) must reach the API server. With a CNI that gives pods real VPC IPs (AWS VPC CNI) the source would be the pod IP and this rule would need rethinking. |
| C2 | tcp 6443 | `CP_SG` | Control-plane nodes calling each other's API server. No effect with one node (see section 1); present so adding control planes later needs no change. |
| C3 | tcp 2379-2380 | `CP_SG` | etcd. 2379 is client traffic, 2380 is peer replication. It holds every Secret and all cluster state; anyone who can reach it bypasses RBAC, so it is open **only** to control-plane nodes, never to workers or a CIDR. |
| C4 | tcp 10250 | `CP_SG` | Kubelet API on control-plane nodes, from other control-plane nodes' API servers. |
| C5 | tcp 10250 | `WK_SG` | metrics-server/Prometheus pods on workers scrape the control-plane kubelet. The kubelet still requires authentication and authorisation; this only opens the network path. |
| C6 | udp 4789 | `CP_SG`, `WK_SG` | VXLAN overlay. When a pod on a worker talks to a pod on the control plane (CoreDNS, Calico), the packet is wrapped in UDP 4789 between node IPs. Without it, nodes show `Ready` while cross-node pod traffic silently fails. |
| C7 | tcp 5473 | `CP_SG`, `WK_SG` | Calico Typha. If blocked, `calico-node` pods stay not-ready. |

## 4. Worker security group (`WK_SG`), inbound

| # | Rule | Source | Why |
|---|---|---|---|
| W1 | tcp 10250 | `CP_SG` | The API server uses the kubelet for logs, exec, port-forward, attach. The kubelet API can run commands in containers, so it is **never** open to the wider VPC. |
| W2 | tcp 10250 | `WK_SG` | Scrapers running on other workers. |
| W3 | udp 4789 | `CP_SG`, `WK_SG` | VXLAN, same as C6 in the other direction. Each side must allow the other because rules apply to the receiver. |
| W4 | tcp 5473 | `CP_SG`, `WK_SG` | Calico Typha, same as C7. |
| W5 | tcp 30000-32767 | VPC CIDR | NodePort range. The smoke test curls `worker-ip:nodeport` from the control plane. Scoped to the VPC so nothing outside can reach it. This is the only CIDR-based rule. |

## 5. Deliberately not open

| Not open | Reason |
|---|---|
| SSH (tcp 22) | SSM Session Manager replaces it: no inbound port, no keys, every session audited |
| tcp 6443 from the internet or `0.0.0.0/0` | The API server is the front door. Admin access goes through an SSM port-forward (lab) or VPN / Direct Connect to an internal NLB (production) |
| tcp 2379 from workers | Raw database access |
| tcp 10257 / 10259 | controller-manager and scheduler serve on localhost only; nothing needs to reach them |
| tcp 10256 (kube-proxy health) | Needed only if a load balancer health-checks it (`externalTrafficPolicy: Local`) |
| ICMP | Add `icmp` from the VPC CIDR if you want to ping while debugging |

## 6. Egress

- **Lab:** left at allow-all so apt, container registries, GitHub and SSM work through the NAT gateway. A rule that was too tight would break package installs immediately, which is a poor lab experience.
- **Production:** restrict it. A workable set:
  - tcp 443 to the VPC endpoints' security group (SSM, ECR, STS, CloudWatch Logs) and to the NAT only where genuinely required
  - the same intra-cluster ports as the inbound rules (workers -> control plane 6443, control plane -> workers 10250, VXLAN, Typha, etcd between control planes)
  - DNS and instance metadata need no rule
  
  If a pod is compromised, tight egress limits exfiltration and callbacks. Pair it with Kubernetes `NetworkPolicy` for pod-level control; security groups only see nodes.

## 7. Scenarios

| Scenario | What changes |
|---|---|
| **Run kubectl from my laptop** | Nothing in the lab: the SSM port-forward connects outbound from the node. In production you allow 6443 from your VPN/Direct Connect range to an internal NLB, not to the nodes. |
| **Add more control-plane nodes** | C2, C3, C4, C6 and C7 start doing real work. Nothing new is needed because they use `CP_SG` as the source. |
| **Install an ingress controller or `Service type=LoadBalancer`** | Create a separate load-balancer SG open on 443 to the intended clients, then change W5 to use that SG as the source instead of the VPC CIDR. The nodes stay unexposed. |
| **Pods need to reach RDS or another database** | Pod traffic leaves as the worker's IP (SNAT), so allow the **worker SG** on the database's SG. This permits every pod on every worker; for tighter control use a dedicated node group + SG, since "security groups for pods" needs the AWS VPC CNI. |
| **metrics-server or Prometheus** | C5 and W2 already cover scraping. Without them `kubectl top` fails with timeouts to port 10250. |
| **Something is unreachable** | Check, in order: security group rules, route tables, network ACLs (stateless: both directions), then the Calico/Kubernetes layer. Turn on VPC Flow Logs and look for `REJECT`. |

## 8. Production layout

| Security group | Allows in | Purpose |
|---|---|---|
| `api-nlb-sg` | 6443 from VPN / admin CIDRs | Entry to the API server |
| `cp-sg` | 6443 from `api-nlb-sg` and `worker-sg`; etcd, 10250, VXLAN, Typha from `cp-sg`; 10250, VXLAN, Typha from `worker-sg` | Control plane |
| `worker-sg` | 10250 from `cp-sg` and monitoring; VXLAN and Typha from nodes; NodePort / 10256 from `lb-sg` | Workers |
| `lb-sg` | 443 from the internet (or a WAF / CloudFront prefix list) | Public ingress |
| `vpce-sg` | 443 from `cp-sg` and `worker-sg` | VPC endpoints |
| `db-sg` | database port from the specific worker group | Data stores |

Manage them as code with review, and enable AWS Config / Security Hub rules that flag `0.0.0.0/0` ingress.
