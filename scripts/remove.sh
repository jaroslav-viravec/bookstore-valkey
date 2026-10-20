#!/usr/bin/env bash
# Remove all bookstore resources from the cluster.
# Deletes the Valkey CR first so the operator can run its finalizers,
# then removes the namespace (which cascades everything else).
set -euo pipefail

NS="bookstore"

echo "==> Deleting Valkey CR (lets operator clean up its resources)"
kubectl delete valkey valkey -n "$NS" --ignore-not-found

echo "==> Waiting for operator to finish cleanup..."
until ! kubectl get valkey valkey -n "$NS" &>/dev/null; do
  printf "."
  sleep 2
done
echo " done"

echo "==> Deleting namespace '$NS'"
kubectl delete namespace "$NS" --ignore-not-found

echo ""
echo "Done. Remaining namespaces:"
kubectl get ns
