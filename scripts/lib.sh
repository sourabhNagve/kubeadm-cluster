#!/usr/bin/env bash
# Shared helpers. Sourced by every script in scripts/; not meant to be executed directly.
#
# Provides:
#   - config loading (config.env) and state loading (.state/cluster.env)
#   - save / unsave      persist or forget a resource ID in the state file
#   - require            abort unless a state variable is set
#   - tag_spec           build an --tag-specifications value
#   - allow_sg/allow_cidr   idempotent security group ingress rules
#   - ssm_exec / b64     run a script on an instance through SSM Run Command

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config.env}"
STATE_FILE="${STATE_FILE:-$ROOT_DIR/.state/cluster.env}"

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE. Run: cp config.env.example config.env"
command -v aws >/dev/null 2>&1 || die "AWS CLI v2 is required (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)"

# shellcheck source=/dev/null
source "$CONFIG_FILE"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
AZ="${AWS_REGION}${AZ_SUFFIX}"
export AZ

# ---------------------------------------------------------------------------
# State: every resource ID we create is written to .state/cluster.env so the
# scripts can be re-run (they skip what already exists) and torn down later.
# ---------------------------------------------------------------------------

# save KEY VALUE
save() {
  local key=$1 value=$2
  sed -i.bak "/^${key}=/d" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"
  printf '%s=%q\n' "$key" "$value" >>"$STATE_FILE"
  printf -v "$key" '%s' "$value"
  export "${key?}"
}

# unsave KEY
unsave() {
  local key=$1
  sed -i.bak "/^${key}=/d" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"
  unset "$key"
}

# require VAR_NAME: abort with a helpful message when an earlier step has not run.
require() {
  [[ -n "${!1:-}" ]] || die "$1 is not set. Run the earlier step first (see README)."
}

# tag_spec RESOURCE_TYPE NAME_SUFFIX
tag_spec() {
  echo "ResourceType=$1,Tags=[{Key=Name,Value=${CLUSTER}-$2},{Key=project,Value=${CLUSTER}}]"
}

# ---------------------------------------------------------------------------
# Security group rules. Both helpers are safe to re-run: an existing rule is
# reported and skipped, any other AWS error aborts the script.
# ---------------------------------------------------------------------------

# allow_sg TARGET_SG PROTO FROM_PORT TO_PORT SOURCE_SG
allow_sg() {
  local out
  if out=$(aws ec2 authorize-security-group-ingress --group-id "$1" \
    --ip-permissions "IpProtocol=$2,FromPort=$3,ToPort=$4,UserIdGroupPairs=[{GroupId=$5}]" 2>&1); then
    info "added   $2/$3-$4  <-  $5  (on $1)"
  elif [[ "$out" == *InvalidPermission.Duplicate* ]]; then
    info "exists  $2/$3-$4  <-  $5  (on $1)"
  else
    die "$out"
  fi
}

# allow_cidr TARGET_SG PROTO FROM_PORT TO_PORT CIDR
allow_cidr() {
  local out
  if out=$(aws ec2 authorize-security-group-ingress --group-id "$1" \
    --ip-permissions "IpProtocol=$2,FromPort=$3,ToPort=$4,IpRanges=[{CidrIp=$5}]" 2>&1); then
    info "added   $2/$3-$4  <-  $5  (on $1)"
  elif [[ "$out" == *InvalidPermission.Duplicate* ]]; then
    info "exists  $2/$3-$4  <-  $5  (on $1)"
  else
    die "$out"
  fi
}

# ---------------------------------------------------------------------------
# SSM Run Command. This is how the scripts configure the nodes: no SSH, no
# bastion. See docs/ssm-guide.md.
# ---------------------------------------------------------------------------

# b64: read stdin, emit base64 on one line (portable between GNU and BSD base64).
b64() { base64 | tr -d '\n'; }

# target_id cp|worker1|worker2|i-xxxx  ->  instance ID
target_id() {
  case "$1" in
    cp) require CP_ID; echo "$CP_ID" ;;
    worker1) require W1_ID; echo "$W1_ID" ;;
    worker2) require W2_ID; echo "$W2_ID" ;;
    i-*) echo "$1" ;;
    *) die "Unknown target '$1' (use cp, worker1, worker2 or an instance ID)" ;;
  esac
}

# ssm_exec INSTANCE_ID BASE64_PAYLOAD
# Runs the decoded payload as a script, as root, on the instance. The payload is
# base64 so no quoting or JSON escaping can break the command. Remote stdout is
# printed on stdout (so callers can capture it); remote stderr and status go to
# stderr. Exits non-zero if the command did not succeed.
ssm_exec() {
  local id=$1 payload=$2 cmd_id status
  local cmd="f=\$(mktemp); echo ${payload} | base64 -d > \$f; bash \$f </dev/null; rc=\$?; rm -f \$f; exit \$rc"

  cmd_id=$(aws ssm send-command \
    --instance-ids "$id" \
    --document-name AWS-RunShellScript \
    --comment "${CLUSTER}" \
    --timeout-seconds 900 \
    --parameters "{\"commands\":[\"${cmd}\"]}" \
    --query Command.CommandId --output text) ||
    die "send-command failed for $id. Is the instance Online in SSM? Run: ./scripts/ssm.sh status"

  # One waiter call polls for ~100 s. Chaining six gives long commands (kubeadm init,
  # image pulls) up to ~600 s without writing a polling loop. A failed command makes the
  # waiter return immediately, so a failure is not delayed by the chain.
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$id" 2>/dev/null ||
    aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$id" 2>/dev/null ||
    aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$id" 2>/dev/null ||
    aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$id" 2>/dev/null ||
    aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$id" 2>/dev/null ||
    aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$id" 2>/dev/null ||
    true

  status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
    --query Status --output text)

  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
    --query StandardOutputContent --output text
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
    --query StandardErrorContent --output text >&2

  [[ "$status" == "Success" ]] || die "Remote command finished with status: $status (instance $id, command $cmd_id)"
}

# ssm_script INSTANCE_ID LOCAL_SCRIPT [ARG...]
# Runs a local script on the instance with the given positional arguments.
ssm_script() {
  local id=$1 file=$2
  shift 2
  [[ -f "$file" ]] || die "Script not found: $file"
  local args=""
  if [[ $# -gt 0 ]]; then
    args=$(printf '%q ' "$@")
  fi
  # Prefix the script with a `set --` line so $1, $2, ... are available to it.
  local payload
  payload=$({ printf 'set -- %s\n' "$args"; cat "$file"; } | b64)
  ssm_exec "$id" "$payload"
}
