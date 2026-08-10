#!/bin/bash
# disaster.sh - Inject two simultaneous failures into the EKS cluster
# Disaster 1: Isolate the "isolate" node (SchedulingDisabled)
# Disaster 2: High CPU load on the "stress" node
#
# Usage:
#   bash scripts/disaster.sh
#   CLUSTER_NAME=my-cluster REGION=eu-central-1 bash scripts/disaster.sh
#   bash scripts/disaster.sh --cluster-name my-cluster --region eu-central-1

set -euo pipefail

# --- Configuration (defaults match terraform/variables.tf) ---
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
READY_TIMEOUT=180
READY_INTERVAL=15
POD_TIMEOUT=60
POD_INTERVAL=10

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/k8s/stress-pod.yaml"

# --- Input validation ---
if [ -z "$CLUSTER_NAME" ] || [ ${#CLUSTER_NAME} -gt 100 ] || ! [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "❌ Invalid cluster name '$CLUSTER_NAME'. Expected letters, digits and hyphens, max 100 characters." >&2
  exit 1
fi
if [ -z "$REGION" ] || [ ${#REGION} -gt 30 ]; then
  echo "❌ Invalid region '$REGION'. Expected a non-empty value of at most 30 characters." >&2
  exit 1
fi

echo "=== EKS Disaster Injection ==="
echo "  Cluster: $CLUSTER_NAME   Region: $REGION"
echo ""

# --- Pre-check: stress manifest must exist before we change anything ---
echo "[0/3] Validating prerequisites..."
if [ ! -r "$MANIFEST" ]; then
  echo "❌ Stress manifest not found or unreadable: $MANIFEST" >&2
  exit 1
fi

if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "❌ Cluster '$CLUSTER_NAME' not found in region '$REGION'." >&2
  exit 1
fi

# Wait for nodes to be Ready. Abort immediately if none are registered at all.
elapsed=0
while :; do
  registered=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  # Column 2 of `kubectl get nodes` is STATUS: "Ready" or "Ready,SchedulingDisabled".
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /(^|,)Ready(,|$)/' | wc -l | tr -d ' ')

  if [ "$registered" -eq 0 ]; then
    echo "❌ No worker nodes registered with the cluster. Aborting." >&2
    kubectl get nodes || true
    exit 1
  fi
  [ "$ready" -ge 2 ] && break
  if [ "$elapsed" -ge "$READY_TIMEOUT" ]; then
    echo "❌ Only $ready node(s) Ready after ${READY_TIMEOUT}s, need 2. Aborting." >&2
    kubectl get nodes || true
    exit 1
  fi
  echo "  ⏳ $ready/2 nodes Ready, re-checking in ${READY_INTERVAL}s..."
  sleep "$READY_INTERVAL"
  elapsed=$((elapsed + READY_INTERVAL))
done
echo "  ✅ $ready nodes are Ready"
echo "  ✅ Stress manifest found"
echo ""

# --- Disaster 1: isolate the node ---
echo "[1/3] Cordoning node with role=isolate..."
if [ "$(kubectl get nodes -l role=isolate --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; then
  echo "❌ No node carries the label role=isolate. Aborting without injecting load." >&2
  kubectl get nodes --show-labels || true
  exit 1
fi
if ! kubectl cordon -l role=isolate; then
  echo "❌ Failed to cordon the role=isolate node(s). Aborting without injecting load." >&2
  kubectl get nodes || true
  exit 1
fi
echo "  ✅ Node isolated (SchedulingDisabled)"
echo ""

# --- Disaster 2: CPU load on the stress node, from the manifest ---
echo "[2/3] Deploying $STRESS_POD_COUNT CPU stress pods to role=stress node..."
for i in $(seq 1 "$STRESS_POD_COUNT"); do
  pod="cpu-stress-$i"
  if kubectl get pod "$pod" >/dev/null 2>&1; then
    echo "  ⚠️  $pod already exists, skipping"
    continue
  fi
  if sed "s/STRESS_POD_NAME/$pod/" "$MANIFEST" | kubectl apply -f - >/dev/null 2>&1; then
    echo "  ✅ $pod deployed"
  else
    echo "  ⚠️  $pod could not be created"
  fi
done
echo ""

# --- Verify the injected state ---
echo "[3/3] Waiting for stress pods to start..."
elapsed=0
while :; do
  active=$(kubectl get pods -l app=cpu-stress --no-headers 2>/dev/null \
    | awk '$3=="Running" || $3=="Completed" || $3=="Succeeded"' | wc -l | tr -d ' ')
  [ "$active" -ge "$STRESS_POD_COUNT" ] && break
  if [ "$elapsed" -ge "$POD_TIMEOUT" ]; then
    echo "❌ Only $active/$STRESS_POD_COUNT stress pods reached Running/Completed after ${POD_TIMEOUT}s:" >&2
    kubectl get pods -l app=cpu-stress -o wide 2>/dev/null \
      | awk 'NR==1 || ($3!="Running" && $3!="Completed" && $3!="Succeeded")' >&2
    exit 1
  fi
  sleep "$POD_INTERVAL"
  elapsed=$((elapsed + POD_INTERVAL))
done
echo "  ✅ $active/$STRESS_POD_COUNT stress pods active"
echo ""

echo "=== Disaster Injected ==="
echo ""
echo "Node state:"
kubectl get nodes -L role
echo ""
echo "Stress pod placement:"
kubectl get pods -l app=cpu-stress -o wide
echo ""
echo "Monitor CloudWatch alarm: ${CLUSTER_NAME}-high-cpu (region $REGION)"
echo "Wait for ALARM state (~1-2 minutes), then open AWS DevOps Agent and enter:"
echo ""
echo "  \"We have an active incident in our EKS cluster \"$CLUSTER_NAME\"."
echo "   Please investigate and report your findings.\""
echo ""
echo "Run 'bash scripts/cleanup.sh' to restore the cluster."
