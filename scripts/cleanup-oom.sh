#!/bin/bash
# cleanup-oom.sh - Restore the cluster after node-level memory exhaustion
#
# Deletes the memory hog pods and waits for the node to clear MemoryPressure.
# Because restartPolicy is Always, these pods keep restarting until deleted, so
# this cleanup is required to end the incident.
#
# Usage:
#   bash scripts/cleanup-oom.sh
#   HOG_POD_COUNT=5 bash scripts/cleanup-oom.sh

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-eks-istanbul}"
REGION="${REGION:-eu-central-1}"
HOG_POD_COUNT="${HOG_POD_COUNT:-5}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="${2:-}"; shift 2 ;;
    --region)       REGION="${2:-}"; shift 2 ;;
    --pods)         HOG_POD_COUNT="${2:-}"; shift 2 ;;
    *) echo "❌ Unknown argument: $1" >&2; exit 1 ;;
  esac
done

POD_TIMEOUT=90
PRESSURE_TIMEOUT=120

echo "=== EKS Cleanup: Memory Exhaustion ==="
echo "  Cluster: $CLUSTER_NAME   Region: $REGION"
echo ""

# --- Step 1: delete by label, then sweep by name for any stragglers ---
echo "[1/3] Deleting memory hog pods..."
if [ "$(kubectl get pods -l app=mem-hog --no-headers 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
  kubectl delete pods -l app=mem-hog --wait=false --grace-period=1 >/dev/null 2>&1 \
    && echo "  ✅ Deletion requested for all app=mem-hog pods" \
    || echo "  ⚠️  Label-based deletion reported an error"
else
  echo "  ℹ️  No pods with label app=mem-hog found"
fi

for i in $(seq 1 "$HOG_POD_COUNT"); do
  pod="mem-hog-$i"
  if kubectl get pod "$pod" >/dev/null 2>&1; then
    kubectl delete pod "$pod" --wait=false --grace-period=1 >/dev/null 2>&1 \
      && echo "  ✅ $pod deletion requested" || true
  fi
done
echo ""

# --- Step 2: confirm the pods actually went away ---
echo "[2/3] Waiting for pods to terminate..."
elapsed=0
while :; do
  remaining=$(kubectl get pods -l app=mem-hog --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" -eq 0 ] && { echo "  ✅ All memory hog pods removed"; break; }
  if [ "$elapsed" -ge "$POD_TIMEOUT" ]; then
    echo "❌ $remaining pod(s) still present after ${POD_TIMEOUT}s:" >&2
    kubectl get pods -l app=mem-hog -o wide >&2
    echo "" >&2
    echo "Force deleting..." >&2
    kubectl delete pods -l app=mem-hog --force --grace-period=0 >/dev/null 2>&1 || true
    sleep 10
    still=$(kubectl get pods -l app=mem-hog --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$still" -gt 0 ]; then
      echo "❌ Force delete did not clear $still pod(s). Manual intervention needed." >&2
      kubectl get nodes -L role >&2
      exit 1
    fi
    echo "  ✅ Force delete cleared the pods" >&2
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
echo ""

# --- Step 3: wait for the node to recover from memory pressure ---
echo "[3/3] Waiting for node memory pressure to clear..."
elapsed=0
while :; do
  pressured=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    print(0); sys.exit()
n = 0
for node in items:
    for c in node.get('status', {}).get('conditions', []):
        if c.get('type') == 'MemoryPressure' and c.get('status') == 'True':
            n += 1
print(n)
" 2>/dev/null || echo 0)
  notready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /(^|,)Ready(,|$)/' | wc -l | tr -d ' ')

  if [ "${pressured:-0}" -eq 0 ] && [ "${notready:-0}" -eq 0 ]; then
    echo "  ✅ No node reports MemoryPressure, all nodes Ready"
    break
  fi
  if [ "$elapsed" -ge "$PRESSURE_TIMEOUT" ]; then
    echo "⚠️  After ${PRESSURE_TIMEOUT}s: $pressured node(s) under MemoryPressure, $notready NotReady." >&2
    echo "    Nodes usually recover on their own once the hog pods are gone." >&2
    echo "    If a node stays wedged, replace it by scaling the node group:" >&2
    echo "      aws eks update-nodegroup-config --region $REGION --cluster-name $CLUSTER_NAME \\" >&2
    echo "        --nodegroup-name ng-istanbul-stress --scaling-config minSize=0,maxSize=2,desiredSize=0" >&2
    break
  fi
  echo "  ⏳ MemoryPressure on $pressured node(s), $notready NotReady, re-checking..."
  sleep 10
  elapsed=$((elapsed + 10))
done
echo ""

echo "=== Cluster Status ==="
kubectl get nodes -L role
echo ""
echo "Node conditions:"
kubectl get nodes -o json 2>/dev/null | python3 -c "
import sys, json
for node in json.load(sys.stdin).get('items', []):
    name = node['metadata']['name']
    role = node['metadata'].get('labels', {}).get('role', '-')
    conds = {c['type']: c['status'] for c in node.get('status', {}).get('conditions', [])}
    print(f\"  {name} (role={role}) Ready={conds.get('Ready')} MemoryPressure={conds.get('MemoryPressure')}\")
" 2>/dev/null || true
echo ""
echo "✅ Cleanup complete"
