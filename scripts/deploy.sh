#!/usr/bin/env bash
# Deploy bookstore + valkey-operator-managed Valkey to the local kind cluster.
set -euo pipefail

CLUSTER="bookstore"
IMAGE="bookstore-api:latest"
NS="bookstore"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$SCRIPTS_DIR/.."

echo "==> Building app image"
docker build -t "$IMAGE" "$DIR/app"

echo "==> Loading image into kind cluster '$CLUSTER'"
kind load docker-image "$IMAGE" --name "$CLUSTER"

echo "==> Applying manifests"
kubectl apply -k "$DIR/k8s/"

echo "==> Waiting for operator to create valkey password secret (valkey-valkey)..."
until kubectl get secret valkey-valkey -n "$NS" &>/dev/null; do
  printf "."
  sleep 3
done
echo " ready"

# When TLS is enabled, the operator also generates the cert secret valkey-valkey-crt
# (ca.crt/tls.crt/tls.key). Wait for it before restarting so the app mounts a
# populated /certs volume immediately instead of racing the optional mount.
TLS_ENABLED="$(kubectl get configmap bookstore-config -n "$NS" -o jsonpath='{.data.VALKEY_TLS_ENABLED}' 2>/dev/null || true)"
if [ "$TLS_ENABLED" = "true" ]; then
  echo "==> TLS enabled; waiting for cert secret (valkey-valkey-crt)..."
  until kubectl get secret valkey-valkey-crt -n "$NS" &>/dev/null; do
    printf "."
    sleep 3
  done
  echo " ready"
fi

echo "==> Restarting app deployment (ensures it picks up the secret)"
kubectl rollout restart deployment/bookstore -n "$NS"
kubectl rollout status deployment/bookstore -n "$NS" --timeout=3600s

echo ""
echo "Done. Bookstore is up:"
kubectl get pods -n "$NS"
