#!/usr/bin/env bash
# Runs ON the control-plane node, as root, through SSM (scripts/08-smoke-test.sh).
# $1 = base64 of k8s/smoke-test.yaml
#
# Proves, in order: scheduling on both workers, pod-to-API networking, NodePort through a
# worker, cluster DNS, and kubelet serving certificates (kubectl logs).
set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf
MANIFEST_B64="${1:?manifest (base64) is required}"
NS=smoke-test

echo "== 1. Deploy"
echo "${MANIFEST_B64}" | base64 -d | kubectl apply -f -
kubectl -n "$NS" rollout status deploy/web --timeout=180s
kubectl -n "$NS" get pods -o wide

echo
echo "== 2. NodePort through a worker"
NODEPORT=$(kubectl -n "$NS" get svc web -o jsonpath='{.spec.ports[0].nodePort}')
WORKER_IP=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -fsS -o /dev/null -w "http://${WORKER_IP}:${NODEPORT} -> HTTP %{http_code}\n" "http://${WORKER_IP}:${NODEPORT}"

echo
echo "== 3. Cluster DNS"
kubectl -n "$NS" run dns-test --image=public.ecr.aws/docker/library/busybox:1.36 \
  --restart=Never -- nslookup kubernetes.default.svc.cluster.local
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/dns-test --timeout=120s
kubectl -n "$NS" logs dns-test

echo
echo "== 4. kubelet serving certificates (kubectl logs goes API server -> kubelet:10250)"
kubectl -n "$NS" logs deploy/web --tail=3

echo
echo "== Cleanup"
kubectl delete namespace "$NS" --wait=false

echo
echo "Smoke test passed."
