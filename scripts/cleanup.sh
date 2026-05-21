#!/bin/bash
# cleanup.sh - Restore the EKS cluster after disaster injection

set -e

echo "=== EKS Istanbul Cleanup ==="
echo ""

# Step 1: Delete stress pods
echo "[1/2] Deleting CPU stress pods..."
for i in $(seq 1 10); do
  kubectl delete pod cpu-stress-$i --ignore-not-found=true 2>/dev/null && \
    echo "  ✅ cpu-stress-$i deleted" || true
done
echo ""

# Step 2: Uncordon isolated node
echo "[2/2] Uncordoning node with role=isolate..."
kubectl uncordon -l role=isolate
echo "  ✅ Node restored"
echo ""

# Verify
echo "=== Cluster Status ==="
kubectl get nodes
echo ""
echo "✅ Cleanup complete"
