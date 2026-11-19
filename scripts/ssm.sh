#!/usr/bin/env bash
# Everyday SSM helper. See docs/ssm-guide.md for how Session Manager works and how to debug it.
#
#   ./scripts/ssm.sh status                       are the instances registered with SSM?
#   ./scripts/ssm.sh shell cp|worker1|worker2     interactive shell (no SSH, no keys)
#   ./scripts/ssm.sh forward-api [local-port]     tunnel the Kubernetes API to localhost
#   ./scripts/ssm.sh kubeconfig [local-port]      write .state/kubeconfig for use with forward-api
#   ./scripts/ssm.sh run TARGET "command"         one-off command as root (kubectl is preconfigured)
#   ./scripts/ssm.sh script TARGET FILE [ARGS]    run a local script on a node as root
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

command -v session-manager-plugin >/dev/null 2>&1 ||
  info "note: session-manager-plugin is not installed; 'shell' and 'forward-api' need it (docs/ssm-guide.md)"

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
  status)
    require CP_ID
    require W1_ID
    require W2_ID
    REGISTERED=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${CP_ID},${W1_ID},${W2_ID}" \
      --query 'length(InstanceInformationList)' --output text)
    aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${CP_ID},${W1_ID},${W2_ID}" \
      --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,PlatformVersion,AgentVersion]' \
      --output table
    if [[ "$REGISTERED" != "3" ]]; then
      echo "Only $REGISTERED of 3 instances are registered. This is normal for the first 3-5 minutes after launch."
      echo "If it persists, see 'Troubleshooting' in docs/ssm-guide.md."
      exit 1
    fi
    echo "All three instances are registered. Check that PingStatus is Online."
    ;;

  shell)
    aws ssm start-session --target "$(target_id "${1:-}")"
    ;;

  forward-api)
    require CP_ID
    PORT="${1:-6443}"
    echo "Forwarding the Kubernetes API to https://127.0.0.1:${PORT} (Ctrl-C to stop)."
    echo "In another terminal:  export KUBECONFIG=$ROOT_DIR/.state/kubeconfig  (create it first with: ./scripts/ssm.sh kubeconfig ${PORT})"
    aws ssm start-session --target "$CP_ID" \
      --document-name AWS-StartPortForwardingSession \
      --parameters "{\"portNumber\":[\"6443\"],\"localPortNumber\":[\"${PORT}\"]}"
    ;;

  kubeconfig)
    require CP_ID
    PORT="${1:-6443}"
    OUT_FILE="$ROOT_DIR/.state/kubeconfig"
    PAYLOAD=$(printf 'cat /etc/kubernetes/admin.conf\n' | b64)
    ssm_exec "$CP_ID" "$PAYLOAD" | sed "s#server: https://.*#server: https://127.0.0.1:${PORT}#" >"$OUT_FILE"
    chmod 600 "$OUT_FILE"
    echo "Wrote $OUT_FILE (cluster-admin credentials: never commit or share it)."
    echo "Start the tunnel in one terminal:   ./scripts/ssm.sh forward-api ${PORT}"
    echo "Use it in another:                  export KUBECONFIG=$OUT_FILE && kubectl get nodes"
    ;;

  run)
    TARGET="$(target_id "${1:-}")"
    shift
    [[ $# -gt 0 ]] || die "Usage: ssm.sh run TARGET \"command\""
    PAYLOAD=$(printf 'export KUBECONFIG=/etc/kubernetes/admin.conf\n%s\n' "$*" | b64)
    ssm_exec "$TARGET" "$PAYLOAD"
    ;;

  script)
    TARGET="$(target_id "${1:-}")"
    FILE="${2:-}"
    [[ -n "$FILE" ]] || die "Usage: ssm.sh script TARGET FILE [ARGS...]"
    shift 2
    ssm_script "$TARGET" "$FILE" "$@"
    ;;

  help | -h | --help | *)
    usage
    ;;
esac
