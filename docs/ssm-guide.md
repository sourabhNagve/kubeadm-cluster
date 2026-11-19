# SSM guide: reaching private nodes without SSH

This cluster has **no SSH, no key pairs, no bastion host and no public IPs**. Everything you do on a node goes through **AWS Systems Manager (SSM)**. This guide explains how that works, what must be true for it to work, every way this repo uses it, and how to debug it.

## 1. What SSM gives you

| Feature | What it is | Used here for |
|---|---|---|
| **Session Manager** | An interactive shell (or a TCP tunnel) on an instance, opened through the AWS API | `ssm.sh shell`, `ssm.sh forward-api` |
| **Run Command** | Run a script on one or more instances and collect its output | Every cluster step: `kubeadm init`, `join`, Calico, smoke test |
| **Fleet inventory** | The list of instances registered with SSM and whether they are `Online` | `ssm.sh status` |

Why this is better than SSH for a cluster:

- **No inbound port.** The security groups have no port 22 and no rule from the internet. The SSM agent on each node makes an *outbound* HTTPS connection to AWS.
- **IAM is the login.** Who may open a shell on which node is an IAM policy, not a key file passed around. Revoking access is removing a policy.
- **Audit by default.** Every `StartSession` and `SendCommand` is a CloudTrail event; session contents can also be logged (section 7).
- **No key management.** Nothing to rotate, leak or forget to delete.

## 2. How it works

```
 your laptop                      AWS                          private subnet
 +-------------+  HTTPS   +----------------+  HTTPS (outbound  +----------------+
 | aws ssm ... | -------> | SSM service    | <---------------- | SSM agent on   |
 | + plugin    |  IAM     | ssm            |   from the node   | the node       |
 +-------------+  auth    | ssmmessages    |   via NAT/endpoint| (snap on       |
                          | ec2messages    |                   |  Ubuntu AMIs)  |
                          +----------------+                   +----------------+
```

1. At boot the **SSM agent** on the node calls the SSM endpoints (`ssm`, `ssmmessages`, `ec2messages`) over **outbound 443**. It authenticates with the **instance profile** credentials, and the node appears in SSM as *managed*.
2. When you run `aws ssm start-session`, the AWS CLI calls the SSM API with **your** IAM identity. SSM checks your permissions, then relays the traffic through the `ssmmessages` channel that the agent already holds open.
3. The Session Manager **plugin** on your laptop handles the terminal stream (or the TCP port forward).

Consequence: a node only needs a route to the internet **or** to VPC endpoints for those three services. In this repo it goes through the NAT gateway.

## 3. Prerequisites checklist

All of these are satisfied by the scripts, but this is the list to check when something does not work.

| # | Requirement | Where it comes from in this repo |
|---|---|---|
| 1 | SSM agent installed and running on the node | Canonical Ubuntu AMIs ship it as a snap (`snap.amazon-ssm-agent.amazon-ssm-agent`) |
| 2 | Instance profile with `AmazonSSMManagedInstanceCore` | `scripts/02-iam.sh`, attached in `04-launch-instances.sh` |
| 3 | Outbound HTTPS to `ssm`, `ssmmessages`, `ec2messages` | Private route table sends `0.0.0.0/0` to the NAT gateway (`01-network.sh`); security groups keep the default allow-all egress |
| 4 | Correct system time on the node | Amazon Time Sync, default on AWS |
| 5 | Your IAM identity may call SSM | Admin, or the policy in [`iam/ssm-operator-policy.json`](../iam/ssm-operator-policy.json) |
| 6 | Session Manager plugin on your laptop | [Install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html); verify with `session-manager-plugin --version` |
| 7 | AWS CLI v2, same region as the cluster | `AWS_REGION` in `config.env`; the scripts export it |

Registration takes **2 to 5 minutes** after launch. This is normal.

## 4. Everyday use

All of these go through `scripts/ssm.sh`. The raw `aws` command is shown so you know what it does.

### 4.1 Are the nodes registered?

```bash
./scripts/ssm.sh status
# raw: aws ssm describe-instance-information --filters Key=InstanceIds,Values=i-aaa,i-bbb,i-ccc
```

You want three rows with `PingStatus = Online`. A node missing from the list has not registered (yet); `ConnectionLost` means it registered earlier but is not reachable now.

### 4.2 Interactive shell

```bash
./scripts/ssm.sh shell cp          # or worker1, worker2, or an instance ID
# raw: aws ssm start-session --target i-0123456789abcdef0
```

You land as `ssm-user` (an auto-created sudoer). For cluster work:

```bash
sudo -i                 # root; kubectl is already configured on the control plane
kubectl get nodes
exit                    # leave root
exit                    # end the session
```

Useful places on a node: `/var/log/k8s-node-prep.log` (boot-time setup), `journalctl -u kubelet`, `journalctl -u containerd`, `/etc/kubernetes/`.

### 4.3 Reach the Kubernetes API from your laptop (port forwarding)

The API server listens on the private IP only. Tunnel it:

```bash
./scripts/ssm.sh kubeconfig        # fetches admin.conf, points it at https://127.0.0.1:6443
./scripts/ssm.sh forward-api       # terminal 1, leave running
export KUBECONFIG=$PWD/.state/kubeconfig   # terminal 2
kubectl get nodes
# raw: aws ssm start-session --target i-<cp> --document-name AWS-StartPortForwardingSession \
#        --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
```

This works with TLS verification on because `127.0.0.1` is in the API server certificate's SANs (`k8s/kubeadm-config.yaml`). If local port 6443 is taken, pass another port to **both** commands: `ssm.sh kubeconfig 6444` and `ssm.sh forward-api 6444`.

> The `kubeconfig` file contains **cluster-admin credentials**. It lives in `.state/` (git-ignored, mode 600). Never commit or share it. See [production-notes.md](production-notes.md) for the OIDC alternative.

### 4.4 Run a one-off command

```bash
./scripts/ssm.sh run cp "kubectl get pods -A"
./scripts/ssm.sh run worker1 "systemctl status kubelet --no-pager | head -5"
```

Commands run as **root** through the `AWS-RunShellScript` document. On the control plane `KUBECONFIG` is preset to `/etc/kubernetes/admin.conf`.

### 4.5 Run a script on a node

```bash
./scripts/ssm.sh script cp scripts/node/post-join.sh
./scripts/ssm.sh script worker1 my-debug.sh arg1 "arg two"     # arguments become $1, $2, ...
```

This is how every cluster step in the repo works. The script is base64-encoded into a single command, so quoting and special characters cannot break it, and it is written to a temp file and executed with `bash` (so scripts can use stdin themselves). Run Command limits to know: the whole command can be about 97 KB, and **at most 24,000 characters of output** are returned (the rest is truncated; log to a file for bigger output).

### 4.6 Copy files

Session Manager has no `scp`. Options:

- **Small text**: include it in a script with a here-doc, or pass it base64-encoded as an argument (this is how the kubeadm config reaches the node).
- **Anything larger**: upload to an S3 bucket from your laptop and `aws s3 cp` from the node. The node role needs S3 read on that bucket (not granted by default; this repo gives the nodes SSM permissions only).
- **Out of a node**: `ssm.sh run cp "cat /path/file" > local-file` works for text files under 24,000 characters.

## 5. Permissions for the people using SSM

An administrator already has everything. For anyone else, use [`iam/ssm-operator-policy.json`](../iam/ssm-operator-policy.json). Replace `ACCOUNT_ID` and the `project` tag value (`k8s-lab` by default). It grants:

| Statement | Effect |
|---|---|
| `StartSession` on instances **tagged `project=<cluster>`** | Open shells and tunnels only on this cluster's nodes |
| `StartSession` on two documents | Interactive shell and port-forward only, not arbitrary documents |
| `TerminateSession` / `ResumeSession` on `session/${aws:username}-*` | You can end only your own sessions |
| `SendCommand` on tagged instances + the `AWS-RunShellScript` document | Run Command on this cluster only |
| Describe/Get calls | `status` and reading command output |

The `ManageOwnSessionsOnly` statement uses `${aws:username}`, which exists for IAM users. If people sign in through IAM Identity Center or an assumed role, use `${aws:userid}` instead (and see the AWS docs, "Sample IAM policies for Session Manager").

The tag condition is why every instance in `04-launch-instances.sh` carries a `project` tag. To grant access to a second cluster, give it a different `CLUSTER` name and add its tag to the policy.

Because these permissions are root on every node (and the control plane holds etcd and cluster-admin credentials), treat them as **cluster-admin equivalent**.

## 6. Why NAT here, and VPC endpoints in production

The lab sends SSM traffic through the NAT gateway because the nodes need the internet anyway (apt, container images). In production you add **interface VPC endpoints** so SSM keeps working without internet egress and the traffic never leaves the AWS network:

| Endpoint | Service name (replace `<region>`) |
|---|---|
| SSM | `com.amazonaws.<region>.ssm` |
| Session channel | `com.amazonaws.<region>.ssmmessages` |
| Run Command channel | `com.amazonaws.<region>.ec2messages` |
| (logging to CloudWatch) | `com.amazonaws.<region>.logs` |
| (logging/transfer via S3) | `com.amazonaws.<region>.s3` (gateway endpoint) |

Create them in the private subnets with private DNS enabled, and attach a security group that allows **tcp 443 from the node security groups**. Nodes must also allow outbound 443 to that group. With these in place a fully private cluster (no NAT) can still be managed.

## 7. Session logging and limits (recommended before sharing the cluster)

Out of the box, SSM records **that** a session happened (CloudTrail) but not **what** was typed. To record the content, set Session Manager preferences (Systems Manager > Session Manager > Preferences, or the `SSM-SessionManagerRunShell` document):

- **CloudWatch Logs** and/or **S3** session logging, optionally encrypted with a KMS key
- **Idle session timeout** (for example 20 minutes) and a **maximum session duration**
- **Run As** to open sessions as a named OS user instead of `ssm-user`
- **KMS encryption** of the session data channel

For logging, the node role also needs `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups`, `logs:DescribeLogStreams` on the log group (and `s3:PutObject` for S3). These are not in the lab role. See the AWS docs, "Logging session activity", for the exact preference document and policies.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ssm.sh status` shows fewer than 3 nodes | Too early, or the agent cannot reach SSM | Wait 5 minutes after launch. Then check the route table, NAT gateway state, and that the instance profile is attached (`aws ec2 describe-instances --query 'Reservations[].Instances[].IamInstanceProfile'`) |
| `TargetNotConnected` on `start-session` | Instance not registered or agent stopped | `ssm.sh status`; if never registered, see the row above; if `ConnectionLost`, the node may be stopped or lost egress |
| `InvalidInstanceId` on `send-command` | Same: not registered yet | Wait and retry |
| `SessionManagerPlugin is not found` | Plugin not installed or not on `PATH` | Install the plugin, restart the terminal, run `session-manager-plugin --version` |
| `AccessDeniedException ... ssm:StartSession` | Your IAM identity lacks permission, or the instance lacks the `project` tag the policy checks | Use an admin or the policy in `iam/`; check instance tags |
| Instance never registers, route and profile look right | Instance profile attached after boot, or IAM not propagated at launch | `aws ec2 reboot-instances` (or `sudo snap restart amazon-ssm-agent` if you have a session) |
| Port forward starts but `kubectl` hangs | `kubeadm init` not finished, or API server down | `ssm.sh run cp "systemctl is-active kubelet; crictl ps \| head"` |
| `x509: certificate is valid for ..., not 127.0.0.1` | Cluster built without `127.0.0.1` in `certSANs` | Use the repo's `kubeadm-config.yaml`; or regenerate API certs with the extra SAN |
| Remote command output ends abruptly | 24,000-character output limit | Write output to a file on the node and fetch it in chunks |
| `Run command timed out` / `InProgress` | The script runs longer than the waiter chain (about 10 minutes) | Check progress: `aws ssm list-command-invocations --command-id <id> --details` |

Node-side debugging (open a shell first):

```bash
sudo snap services amazon-ssm-agent          # is the agent active?
sudo journalctl -u snap.amazon-ssm-agent.amazon-ssm-agent -n 50 --no-pager
sudo tail -n 50 /var/log/amazon/ssm/amazon-ssm-agent.log
curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' https://ssm.us-east-1.amazonaws.com   # reachability (any HTTP code means the network path works)
```

If you cannot open a shell at all, use the EC2 console's **Get system log** (`aws ec2 get-console-output --instance-id <id> --output text`) to see cloud-init output.

## 9. Going further

- **Tag-based access per team/environment**: put `env=dev|prod` tags on instances and tighten the policy condition (`ssm:resourceTag/env`).
- **Break-glass**: keep one IAM role that can open sessions on all nodes, with MFA required and alerts on use (CloudTrail + EventBridge on `StartSession`).
- **Approvals/just-in-time access**: grant session permissions through short-lived IAM Identity Center permission sets.
- **Patching**: SSM Patch Manager can patch nodes in maintenance windows (see [production-notes.md](production-notes.md)).
- **SSH over SSM**: possible with the `AWS-StartSSHSession` document if you ever need `scp` or an editor integration, but it brings key management back; this repo deliberately avoids it.
