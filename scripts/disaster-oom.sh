#!/bin/bash
# disaster-oom.sh - Inject NODE-LEVEL memory exhaustion into the EKS cluster
#
# Failure chain this produces:
#   memory hog pods (no limits) -> node memory exhausted -> kernel OOM killer
#   -> containers OOMKilled (exit 137) -> kubelet restarts -> OOMKilled again
#   -> exponential backoff -> CrashLoopBackOff, climbing RESTARTS count
#
# Blast radius is confined to the role=stress node. The role=isolate node is
# left healthy on purpose so the investigation has a control to compare against.
#
# Usage:
#   bash scripts/disaster-oom.sh
#   CLUSTER_NAME=my-cluster REGION=eu-central-1 bash scripts/disaster-oom.sh
#   bash scripts/disaster-oom.sh --cluster-name my-cluster --region eu-central-1
#   bash scripts/disaster-oom.sh --pods 5 --bytes 900M

set -euo pipefail

# --- Configuration (defaults match terraform/variables.tf) ---
CLUSTER_NAME="${CLUSTER_NAME:-eks-istanbul}"
REGION="${REGION:-eu-central-1}"

# 5 pods x 900M against ~3.07Gi allocatable overshoots the node decisively,
# which is what forces kernel OOM rather than a graceful kubelet eviction.
HOG_POD_COUNT="${HOG_POD_COUNT:-5}"
HOG_BYTES="${HOG_BYTES:-900M}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="${2:-}"; shift 2 ;;
    --region)       REGION="${2:-}"; shift 2 ;;
    --pods)         HOG_POD_COUNT="${2:-}"; shift 2 ;;
    --bytes)        HOG_BYTES="${2:-}"; shift 2 ;;
    *) echo "❌ Unknown argument: $1" >&2; exit 1 ;;
  esac
done

READY_TIMEOUT=180
READY_INTERVAL=15
OOM_TIMEOUT=180
OOM_INTERVAL=15

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/k8s/memory-hog-pod.yaml"

# --- Input validation ---
if [ -z "$CLUSTER_NAME" ] || [ ${#CLUSTER_NAME} -gt 100 ] || ! [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "❌ Invalid cluster name '$CLUSTER_NAME'. Expected letters, digits and hyphens, max 100 characters." >&2
  exit 1
fi
if [ -z "$REGION" ] || [ ${#REGION} -gt 30 ]; then
  echo "❌ Invalid region '$REGION'. Expected a non-empty value of at most 30 characters." >&2
  exit 1
fi
if ! [[ "$HOG_POD_COUNT" =~ ^[0-9]+$ ]] || [ "$HOG_POD_COUNT" -lt 1 ] || [ "$HOG_POD_COUNT" -gt 20 ]; then
  echo "❌ Invalid pod count '$HOG_POD_COUNT'. Expected an integer between 1 and 20." >&2
  exit 1
fi
if ! [[ "$HOG_BYTES" =~ ^[0-9]+[KMG]$ ]]; then
  echo "❌ Invalid byte size '$HOG_BYTES'. Expected a value such as 900M or 1G." >&2
  exit 1
fi

echo "=== EKS Disaster Injection: Node-Level Memory Exhaustion ==="
echo "  Cluster: $CLUSTER_NAME   Region: $REGION"
echo "  Plan:    $HOG_POD_COUNT pods x $HOG_BYTES on the role=stress node"
echo ""

# --- Pre-flight: fail before changing anything ---
echo "[0/3] Validating prerequisites..."
if [ ! -r "$MANIFEST" ]; then
  echo "❌ Memory hog manifest not found or unreadable: $MANIFEST" >&2
  exit 1
fi
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "❌ Cluster '$CLUSTER_NAME' not found in region '$REGION'." >&2
  exit 1
fi

elapsed=0
while :; do
  registered=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
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

STRESS_NODE=$(kubectl get nodes -l role=stress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$STRESS_NODE" ]; then
  echo "❌ No node carries the label role=stress. Aborting without injecting load." >&2
  kubectl get nodes --show-labels || true
  exit 1
fi
echo "  ✅ $ready nodes Ready"
echo "  ✅ Target node: $STRESS_NODE"
echo "  ✅ Manifest found"
echo ""

# --- Record the pre-incident baseline for comparison ---
echo "[1/3] Baseline memory on target node..."
kubectl describe node "$STRESS_NODE" 2>/dev/null \
  | sed -n '/Allocated resources/,/Events/p' | grep -E 'memory' || true
echo ""

# --- Inject: memory hog pods with no limits ---
echo "[2/3] Deploying $HOG_POD_COUNT memory hog pods ($HOG_BYTES each)..."
for i in $(seq 1 "$HOG_POD_COUNT"); do
  pod="mem-hog-$i"
  if kubectl get pod "$pod" >/dev/null 2>&1; then
    echo "  ⚠️  $pod already exists, skipping"
    continue
  fi
  if sed -e "s/MEMORY_HOG_NAME/$pod/" -e "s/MEMORY_HOG_BYTES/$HOG_BYTES/" "$MANIFEST" \
      | kubectl apply -f - >/dev/null 2>&1; then
    echo "  ✅ $pod deployed"
  else
    echo "  ⚠️  $pod could not be created"
  fi
done
echo ""

# --- Wait for the OOM signature to appear ---
echo "[3/3] Waiting for OOMKill / CrashLoopBackOff signature..."
elapsed=0
oom_seen=0
while [ "$elapsed" -lt "$OOM_TIMEOUT" ]; do
  # Count containers the kernel has OOMKilled (current or previous state).
  oom_count=$(kubectl get pods -l app=mem-hog -o json 2>/dev/null | python3 -c "
import sys, json
try:
    pods = json.load(sys.stdin).get('items', [])
except Exception:
    print(0); sys.exit()
n = 0
for p in pods:
    for cs in p.get('status', {}).get('containerStatuses', []) or []:
        for st in (cs.get('state', {}), cs.get('lastState', {})):
            t = st.get('terminated') or {}
            if t.get('reason') == 'OOMKilled':
                n += 1
print(n)
" 2>/dev/null || echo 0)

  restarts=$(kubectl get pods -l app=mem-hog --no-headers 2>/dev/null | awk '{s+=$4} END {print s+0}')
  crashloop=$(kubectl get pods -l app=mem-hog --no-headers 2>/dev/null | grep -c 'CrashLoopBackOff' || true)

  echo "  [${elapsed}s] OOMKilled: $oom_count   restarts: $restarts   CrashLoopBackOff: $crashloop"
  if [ "${oom_count:-0}" -gt 0 ] || [ "${restarts:-0}" -gt 0 ]; then
    oom_seen=1
    # Give the loop a little longer so RESTARTS climbs visibly for the demo.
    [ "$elapsed" -ge 60 ] && break
  fi
  sleep "$OOM_INTERVAL"
  elapsed=$((elapsed + OOM_INTERVAL))
done

if [ "$oom_seen" -eq 0 ]; then
  echo "⚠️  No OOMKill observed after ${OOM_TIMEOUT}s." >&2
  echo "    The node may have absorbed the load, or kubelet evicted pods gracefully" >&2
  echo "    instead of the kernel OOM killer firing. Try a larger --bytes value." >&2
  kubectl get pods -l app=mem-hog -o wide >&2 || true
  kubectl get events --field-selector reason=Evicted 2>/dev/null | head -5 >&2 || true
  exit 1
fi
echo ""

echo "=== Disaster Injected: Node-Level Memory Exhaustion ==="
echo ""
echo "Node state:"
kubectl get nodes -L role
echo ""
echo "Memory pressure condition on $STRESS_NODE:"
kubectl get node "$STRESS_NODE" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null \
  | grep -E 'MemoryPressure|Ready' || true
echo ""
echo "Pod state:"
kubectl get pods -l app=mem-hog -o wide
echo ""
echo "Termination reasons (kernel OOM evidence):"
kubectl get pods -l app=mem-hog -o json 2>/dev/null | python3 -c "
import sys, json
pods = json.load(sys.stdin).get('items', [])
for p in pods:
    name = p['metadata']['name']
    for cs in p.get('status', {}).get('containerStatuses', []) or []:
        last = (cs.get('lastState', {}).get('terminated') or {})
        cur  = (cs.get('state', {}).get('waiting') or {})
        if last:
            print(f\"  {name}: last terminated reason={last.get('reason')} exit={last.get('exitCode')} restarts={cs.get('restartCount')}\")
        elif cur:
            print(f\"  {name}: waiting reason={cur.get('reason')} restarts={cs.get('restartCount')}\")
" 2>/dev/null || true
echo ""
echo "Recent OOM / eviction events:"
kubectl get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -iE 'oom|evict|memorypressure|backoff' | tail -8 || echo "  (none surfaced yet)"
echo ""
echo "Monitor CloudWatch (region $REGION), namespace ContainerInsights:"
echo "  node_memory_utilization              - climbing on the stress node"
echo "  node_status_condition_memory_pressure - node under memory pressure"
echo "  container_memory_failures_total       - kernel OOM kill counter"
echo "  pod_number_of_container_restarts      - restart loop"
echo ""
echo "Then open AWS DevOps Agent and enter:"
echo ""
echo "  \"We have an active incident in our EKS cluster \"$CLUSTER_NAME\"."
echo "   Please investigate and report your findings.\""
echo ""
echo "Run 'bash scripts/cleanup-oom.sh' to restore the cluster."
