#!/bin/bash
# cleanup.sh - Restore the EKS cluster after disaster injection
#
# Usage:
#   bash scripts/cleanup.sh
#   CLUSTER_NAME=my-cluster REGION=eu-central-1 bash scripts/cleanup.sh

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-eks-istanbul}"
REGION="${REGION:-eu-central-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="${2:-}"; shift 2 ;;
    --region)       REGION="${2:-}"; shift 2 ;;
    *) echo "❌ Unknown argument: $1" >&2; exit 1 ;;
  esac
done

STRESS_POD_COUNT=6
POD_TIMEOUT=60

echo "=== EKS Cleanup ==="
echo "  Cluster: $CLUSTER_NAME   Region: $REGION"
echo ""

# --- Step 1: delete stress pods (absent pods are not an error) ---
echo "[1/2] Deleting CPU stress pods..."
for i in $(seq 1 "$STRESS_POD_COUNT"); do
  pod="cpu-stress-$i"
  if kubectl get pod "$pod" >/dev/null 2>&1; then
    kubectl delete pod "$pod" --wait=false >/dev/null 2>&1 \
      && echo "  ✅ $pod deletion requested" \
      || echo "  ⚠️  $pod deletion request failed"
  else
    echo "  ℹ️  $pod not present, skipping"
  fi
done
echo ""

# --- Step 2: lift the isolation ---
echo "[2/2] Uncordoning node with role=isolate..."
if [ "$(kubectl get nodes -l role=isolate --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; then
  echo "  ℹ️  No node carries the label role=isolate, nothing to uncordon"
else
  kubectl uncordon -l role=isolate >/dev/null 2>&1 \
    && echo "  ✅ Node restored" \
    || echo "  ⚠️  Uncordon reported an error"
fi
echo ""

# --- Confirm pods actually went away ---
elapsed=0
while :; do
  remaining=$(kubectl get pods -l app=cpu-stress --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" -eq 0 ] && break
  if [ "$elapsed" -ge "$POD_TIMEOUT" ]; then
    echo "❌ $remaining stress pod(s) still present after ${POD_TIMEOUT}s:" >&2
    kubectl get pods -l app=cpu-stress -o wide >&2
    echo ""
    echo "Node state:"
    kubectl get nodes -L role
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

echo "=== Cluster Status ==="
kubectl get nodes -L role
echo ""
echo "✅ Cleanup complete"
