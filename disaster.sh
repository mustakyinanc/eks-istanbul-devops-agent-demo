#!/bin/bash
# disaster.sh - Inject two simultaneous failures into the EKS cluster
# Disaster 1: Isolate the "isolate" node (SchedulingDisabled)
# Disaster 2: High CPU load on the "stress" node

set -e

echo "=== EKS Istanbul Disaster Injection ==="
echo ""

# Pre-check: verify nodes are ready
echo "[0/3] Checking cluster state..."
NODE_COUNT=$(kubectl get nodes --no-headers | grep -c "Ready")
if [ "$NODE_COUNT" -lt 2 ]; then
  echo "❌ Less than 2 nodes are Ready. Aborting."
  kubectl get nodes
  exit 1
fi
echo "  ✅ $NODE_COUNT nodes are Ready"
echo ""

# Step 1: Isolate the node
echo "[1/3] Cordoning node with role=isolate..."
kubectl cordon -l role=isolate
echo "  ✅ Node isolated (SchedulingDisabled)"
echo ""

# Step 2: Deploy CPU stress pods to stress node
echo "[2/3] Deploying CPU stress pods to role=stress node..."
for i in $(seq 1 10); do
  kubectl run cpu-stress-$i \
    --image=hande007/stress-ng \
    --restart=Never \
    --overrides='{"spec": {"nodeSelector": {"role": "stress"}}}' \
    -- --cpu 2 --timeout 600s \
    2>/dev/null && echo "  ✅ cpu-stress-$i deployed" || echo "  ⚠️  cpu-stress-$i already exists"
done
echo ""

# Step 3: Verify pods are running on stress node
echo "[3/3] Verifying stress pods are running..."
sleep 10
kubectl get pods -o wide | grep cpu-stress
echo ""

echo "=== Disaster Injected ==="
echo ""
echo "Current cluster state:"
kubectl get nodes
echo ""
echo "Monitor CloudWatch: eks-istanbul-high-cpu alarm"
echo "Wait for ALARM state (~1-2 minutes), then open AWS DevOps Agent and enter:"
echo ""
echo '  "We have an active incident in our EKS cluster "eks-istanbul".'
echo '   Please investigate and report your findings."'
echo ""
echo "Run 'bash scripts/cleanup.sh' to restore the cluster."
