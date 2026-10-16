#!/bin/bash
# disaster-loop.sh - Re-inject Scenario A every 60 seconds for a fixed duration.
#
# Why recycle rather than re-run disaster.sh verbatim: disaster.sh skips pods
# that already exist, and each stress pod lives 600s. Simply calling it every
# minute would be a no-op after the first cycle. This deletes and recreates the
# stress pods each cycle so CPU load is continuous and the event history shows
# real churn. The role=isolate cordon is applied once and left in place.
#
# Usage:
#   bash scripts/disaster-loop.sh              # 10 cycles, 60s apart
#   CYCLES=5 INTERVAL=120 bash scripts/disaster-loop.sh

set -uo pipefail

CYCLES="${CYCLES:-10}"
INTERVAL="${INTERVAL:-60}"
POD_COUNT="${POD_COUNT:-6}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/k8s/stress-pod.yaml"

if [ ! -r "$MANIFEST" ]; then
  echo "❌ Stress manifest not readable: $MANIFEST" >&2
  exit 1
fi

echo "=== Scenario A repeat injection: $CYCLES cycles, ${INTERVAL}s apart ==="
echo ""

# Cordon once; leave it in place for the whole run.
if [ "$(kubectl get nodes -l role=isolate --no-headers 2>/dev/null | grep -c SchedulingDisabled)" -eq 0 ]; then
  kubectl cordon -l role=isolate >/dev/null 2>&1 \
    && echo "Cordoned role=isolate node" \
    || echo "⚠️  Cordon failed" >&2
else
  echo "role=isolate node already cordoned"
fi
echo ""

for c in $(seq 1 "$CYCLES"); do
  ts=$(date -u '+%H:%M:%SZ')
  # Recycle: remove the previous batch so the new one actually starts.
  kubectl delete pods -l app=cpu-stress --wait=false --grace-period=1 >/dev/null 2>&1 || true
  sleep 5

  created=0
  for i in $(seq 1 "$POD_COUNT"); do
    if sed "s/STRESS_POD_NAME/cpu-stress-$i/" "$MANIFEST" \
        | kubectl apply -f - >/dev/null 2>&1; then
      created=$((created + 1))
    fi
  done

  cpu=$(aws cloudwatch describe-alarms --region "${REGION:-eu-central-1}" \
    --alarm-names "${CLUSTER_NAME:-eks-istanbul}-high-cpu" \
    --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo '?')

  echo "[cycle $c/$CYCLES $ts] recreated $created/$POD_COUNT pods, cpu alarm=$cpu"

  [ "$c" -lt "$CYCLES" ] && sleep "$((INTERVAL - 5))"
done

echo ""
echo "=== Repeat injection finished ==="
kubectl get nodes -L role
echo ""
kubectl get pods -l app=cpu-stress -o wide 2>/dev/null | head -8
echo ""
echo "Run 'bash scripts/cleanup.sh' to restore the cluster."
