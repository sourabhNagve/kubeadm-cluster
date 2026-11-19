#!/usr/bin/env bash
# Runs ON the control-plane node, as root, through SSM (scripts/07-join-workers.sh).
# Prints a join command with a fresh token that expires after one hour. A join token is a
# bearer credential: it is never written to disk by this repo and expires quickly.
set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf
kubeadm token create --ttl 1h --print-join-command
