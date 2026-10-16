#!/bin/bash
# setup-monitoring.sh - Phase 1: install the in-cluster metric exporters.
#
# What this does:
#   1. verifies kubectl is executable and that the current context points at
#      the demo cluster, BEFORE anything is applied
#   2. applies the three manifests in k8s/monitoring/ with plain kubectl
#   3. waits for all 3 expected pods (1 kube-state-metrics + 2 node-exporter)
#      to become Ready, polling every 15s for at most 300s
#   4. prints the phase name and result on the final line
#
# SCOPE - PHASE 1 ONLY (Requirement 12.1)
# ---------------------------------------
# This script creates Kubernetes objects and nothing else. It creates NO AWS
# resources, no Capability Provider, no DevOps Agent Space changes, no Grafana Cloud objects
# and no CloudWatch objects. It does not touch the existing CloudWatch
# Container Insights addon or the three CloudWatch alarms. Phase 2 (DevOps
# Agent integration) is entirely manual and is documented in the demo guide.
#
# WHY prometheus.yml IS NOT APPLIED
# ---------------------------------
# k8s/monitoring/ also holds prometheus.yml. That file is the Prometheus server
# configuration for the out-of-cluster EC2 host, placed by
# scripts/provision-monitoring-instance.sh. It is NOT a Kubernetes manifest and
# `kubectl apply` would reject it. The three manifests are therefore listed
# explicitly below rather than globbed, so a new non-manifest file dropped into
# that directory cannot be swept into the cluster by accident.
#
# NO SECRETS HERE
# ---------------
# The Grafana Cloud remote_write credentials belong to the EC2 host, not the
# cluster. Nothing in this script reads, writes or prints a credential, and no
# Kubernetes Secret is created.
#
# NETWORK EXPOSURE
# ----------------
# The manifests publish node-exporter on hostPort 9100 and kube-state-metrics
# on NodePort 30808 so out-of-cluster Prometheus can scrape them. Both serve
# unauthenticated plaintext metrics, so reachability is the entire control, and
# that control lives in the cluster security group (Terraform task 3.2): the
# Monitoring_Security_Group is the named source, never 0.0.0.0/0. This script
# creates no Service of type LoadBalancer and no Ingress, so it opens no new
# internet-reachable path by itself.
#
# Usage:
#   bash scripts/setup-monitoring.sh
#   CLUSTER_NAME=my-cluster REGION=eu-central-1 bash scripts/setup-monitoring.sh
#   bash scripts/setup-monitoring.sh --cluster-name my-cluster --region eu-central-1
#
# Re-running is safe and is expected: `kubectl apply` is declarative, so a
# second run on an unchanged cluster reports every object unchanged, leaves the
# same 3 pods running with untouched restart counters, and exits 0.
#
# Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.10, 13.2, 13.3

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

NAMESPACE="monitoring"
# Requirement 12.4: 3 pods, 300s ceiling, poll interval at most 15s.
EXPECTED_PODS=3
READY_TIMEOUT=300
READY_INTERVAL=15
# Requirement 12.2: the prerequisite checks must complete within 10 seconds,
# so every API call in that phase carries this timeout.
API_TIMEOUT=10s

# Both components in one selector, so the ready count covers exactly the pods
# this script is responsible for and nothing else in the namespace.
POD_SELECTOR='app.kubernetes.io/name in (node-exporter,kube-state-metrics)'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_DIR="$REPO_ROOT/k8s/monitoring"

# Applied in this order on purpose: the namespace and RBAC must exist before
# the workloads that live in it and run under it.
MANIFESTS=(
  "00-namespace-rbac.yaml"
  "10-node-exporter.yaml"
  "20-kube-state-metrics.yaml"
)

PHASE="Phase 1 In-Cluster Exporters"
CURRENT_STEP="startup"

# Requirement 12.10: the last line always names the phase and the result, and
# on failure it names the step that failed.
die() {
  echo "❌ $*" >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
}

# --- Input validation ---
if [ -z "$CLUSTER_NAME" ] || [ ${#CLUSTER_NAME} -gt 100 ] || ! [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9-]+$ ]]; then
  die "Invalid cluster name '$CLUSTER_NAME'. Expected letters, digits and hyphens, max 100 characters."
fi
if [ -z "$REGION" ] || [ ${#REGION} -gt 30 ]; then
  die "Invalid region '$REGION'. Expected a non-empty value of at most 30 characters."
fi

echo "=== $PHASE: setup ==="
echo "  Cluster: $CLUSTER_NAME   Region: $REGION   Namespace: $NAMESPACE"
echo "  Expected pods: $EXPECTED_PODS (1 kube-state-metrics + 2 node-exporter)"
echo ""

# ---------------------------------------------------------------------------
# [1/3] Prerequisites (Requirements 12.2, 12.3, 13.2, 13.3).
#
# Nothing is applied until every check here passes, so a missing tool or a
# drifted context leaves the cluster exactly as it was.
# ---------------------------------------------------------------------------
CURRENT_STEP="1/3 prerequisites"
echo "[1/3] Validating prerequisites..."

# Requirement 13.2 / 13.3: kubectl is the ONLY external tool this script calls.
# A missing kubectl is named, pointed at the README, and nothing is applied.
if ! command -v kubectl >/dev/null 2>&1; then
  echo "❌ Required tool 'kubectl' not found on this machine." >&2
  echo "   This script calls kubectl and nothing else — Helm is not needed." >&2
  echo "   See the prerequisites table in README.md for the kubectl row." >&2
  echo "   No manifest was applied." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi
echo "  ✅ kubectl available: $(command -v kubectl)"

# Requirement 12.3: the context must point at the demo cluster. This has
# drifted to docker-desktop in practice, and applying these manifests to the
# wrong cluster is exactly the mistake worth refusing to make.
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [ -z "$CURRENT_CONTEXT" ]; then
  echo "❌ No current kubectl context is set." >&2
  echo "   Expected a context for cluster '$CLUSTER_NAME'." >&2
  echo "   Fix with:" >&2
  echo "     aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME" >&2
  echo "   No manifest was applied." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi

# The suffix is matched rather than the full ARN: the account id in
# arn:aws:eks:<region>:<account>:cluster/<name> differs per account, and
# hardcoding one would make this script work in a single account only. A
# plain alias equal to the cluster name is accepted too.
context_matches=false
case "$CURRENT_CONTEXT" in
  *"cluster/$CLUSTER_NAME") context_matches=true ;;
  "$CLUSTER_NAME")          context_matches=true ;;
esac

if [ "$context_matches" != true ]; then
  echo "❌ Current kubectl context does not point at the demo cluster." >&2
  echo "     current:  $CURRENT_CONTEXT" >&2
  echo "     expected: a context ending in 'cluster/$CLUSTER_NAME'" >&2
  echo "               (for example arn:aws:eks:$REGION:<account-id>:cluster/$CLUSTER_NAME)" >&2
  echo "   Fix with:" >&2
  echo "     aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME" >&2
  echo "   No manifest was applied; the cluster is unchanged." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi
echo "  ✅ Context points at '$CLUSTER_NAME': $CURRENT_CONTEXT"

# A context can name the right cluster and still be unusable (expired
# credentials, unreachable endpoint). Catching that here keeps the failure in
# the prerequisite step rather than surfacing it mid-apply.
if ! kubectl --request-timeout="$API_TIMEOUT" get --raw /version >/dev/null 2>&1; then
  echo "❌ Cannot reach the Kubernetes API for context '$CURRENT_CONTEXT' within $API_TIMEOUT." >&2
  echo "   Check your AWS credentials and that the cluster endpoint is reachable:" >&2
  echo "     aws eks describe-cluster --name $CLUSTER_NAME --region $REGION" >&2
  echo "   No manifest was applied." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi
echo "  ✅ Kubernetes API reachable"

for manifest in "${MANIFESTS[@]}"; do
  [ -r "$MANIFEST_DIR/$manifest" ] \
    || die "Manifest not found or unreadable: $MANIFEST_DIR/$manifest"
done
echo "  ✅ All ${#MANIFESTS[@]} manifests present in k8s/monitoring/"

# The node-exporter DaemonSet produces one pod per node, so the 3-pod
# expectation assumes exactly 2 workers. A different node count is reported
# rather than silently changing the expectation.
node_total=$(kubectl --request-timeout="$API_TIMEOUT" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
node_ready=$(kubectl --request-timeout="$API_TIMEOUT" get nodes --no-headers 2>/dev/null \
  | awk '$2 ~ /(^|,)Ready(,|$)/' | wc -l | tr -d ' ')
if [ "$node_ready" -eq 0 ]; then
  die "No worker nodes are Ready. The exporters would stay Pending; aborting before applying anything."
fi
if [ "$node_ready" -ne 2 ]; then
  echo "  ⚠️  $node_ready/$node_total node(s) Ready, expected 2."
  echo "     node-exporter is a DaemonSet, so it yields one pod per node; with a"
  echo "     node count other than 2 the $EXPECTED_PODS-pod expectation may not be reachable."
else
  echo "  ✅ $node_ready/$node_total nodes Ready"
fi

# kube-state-metrics pins itself to role=isolate, so without that label it
# would sit Pending until the 300s timeout for a reason worth naming now.
if [ "$(kubectl --request-timeout="$API_TIMEOUT" get nodes -l role=isolate --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; then
  echo "  ⚠️  No node carries the label role=isolate."
  echo "     kube-state-metrics has nodeSelector role=isolate and will remain Pending."
else
  echo "  ✅ A node carries role=isolate for kube-state-metrics"
fi
echo ""

# ---------------------------------------------------------------------------
# [2/3] Apply the manifests (Requirement 12.1).
#
# `kubectl apply` is declarative, which is what makes a second run a no-op:
# every object is reported "unchanged", no pod is recreated and no restart
# counter moves (Requirement 12.9).
# ---------------------------------------------------------------------------
CURRENT_STEP="2/3 apply manifests"
echo "[2/3] Applying k8s/monitoring/ manifests..."

for manifest in "${MANIFESTS[@]}"; do
  if ! apply_output="$(kubectl apply -f "$MANIFEST_DIR/$manifest" 2>&1)"; then
    echo "$apply_output" | sed 's/^/     /' >&2
    die "kubectl apply failed for $manifest. Objects applied before this point were left in place."
  fi
  echo "  ✅ $manifest"
  printf '%s\n' "$apply_output" | sed 's/^/       /'
done
echo ""

# ---------------------------------------------------------------------------
# [3/3] Wait for readiness (Requirements 12.4, 12.5).
#
# A polling loop rather than `kubectl wait`: `kubectl wait` needs the pods to
# exist already and cannot report a running count, and Requirement 12.4 asks
# for the ready count against the expected count on every poll.
# ---------------------------------------------------------------------------
CURRENT_STEP="3/3 wait for readiness"
echo "[3/3] Waiting for $EXPECTED_PODS pods to become Ready (max ${READY_TIMEOUT}s, polling every ${READY_INTERVAL}s)..."

# A pod counts as ready when its READY column reads n/n with n greater than
# zero and its status is Running. Parsing `kubectl get pods` keeps this to one
# API call per poll and avoids go-template variable assignment, which differs
# across kubectl versions.
count_ready_pods() {
  kubectl get pods -n "$NAMESPACE" -l "$POD_SELECTOR" --no-headers 2>/dev/null \
    | awk '{split($2, a, "/"); if (a[2] != "" && a[1] == a[2] && a[1] != "0" && $3 == "Running") c++} END {print c + 0}'
}

# Requirement 12.5: name every pod that is not Ready, with its phase and the
# reason it is not Ready. Container waiting/terminated reasons and false pod
# conditions (Unschedulable being the common one here) both carry that reason.
report_not_ready_pods() {
  local not_ready
  not_ready="$(kubectl get pods -n "$NAMESPACE" -l "$POD_SELECTOR" --no-headers 2>/dev/null \
    | awk '{split($2, a, "/"); if (!(a[2] != "" && a[1] == a[2] && a[1] != "0" && $3 == "Running")) print $1}')"

  if [ -z "$not_ready" ]; then
    echo "     (no pods matching the exporter selector exist in namespace $NAMESPACE)" >&2
    return
  fi

  local pod
  while IFS= read -r pod; do
    [ -n "$pod" ] || continue
    local phase ready_cond reasons
    phase="$(kubectl get pod "$pod" -n "$NAMESPACE" -o go-template='{{.status.phase}}' 2>/dev/null || echo 'Unknown')"
    ready_cond="$(kubectl get pod "$pod" -n "$NAMESPACE" \
      -o go-template='{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}' 2>/dev/null || echo 'Unknown')"
    echo "     - $pod: phase=$phase ready=$ready_cond" >&2

    # Container-level reasons: ImagePullBackOff, CrashLoopBackOff, OOMKilled.
    reasons="$(kubectl get pod "$pod" -n "$NAMESPACE" -o go-template='{{range .status.containerStatuses}}{{if .state.waiting}}{{.name}} waiting: {{.state.waiting.reason}} {{.state.waiting.message}}{{"\n"}}{{end}}{{if .state.terminated}}{{.name}} terminated: {{.state.terminated.reason}} (exit {{.state.terminated.exitCode}}){{"\n"}}{{end}}{{end}}' 2>/dev/null || true)"
    # Pod-level reasons: Unschedulable, ContainersNotReady.
    reasons="$reasons$(kubectl get pod "$pod" -n "$NAMESPACE" -o go-template='{{range .status.conditions}}{{if eq .status "False"}}{{.type}}=False: {{.reason}} {{.message}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)"

    if [ -n "$(printf '%s' "$reasons" | tr -d '[:space:]')" ]; then
      printf '%s\n' "$reasons" | sed '/^[[:space:]]*$/d; s/^/         reason: /' >&2
    else
      echo "         reason: not reported by the API; see 'kubectl describe pod $pod -n $NAMESPACE'" >&2
    fi
  done <<< "$not_ready"
}

elapsed=0
while :; do
  ready="$(count_ready_pods)"
  echo "  ⏳ $ready/$EXPECTED_PODS pods Ready (${elapsed}s/${READY_TIMEOUT}s)"
  [ "$ready" -ge "$EXPECTED_PODS" ] && break

  if [ "$elapsed" -ge "$READY_TIMEOUT" ]; then
    echo "❌ Only $ready/$EXPECTED_PODS pods became Ready within ${READY_TIMEOUT}s." >&2
    echo "   Pods that are not Ready:" >&2
    report_not_ready_pods
    echo "" >&2
    kubectl get pods -n "$NAMESPACE" -o wide >&2 2>/dev/null || true
    echo "" >&2
    # Requirement 12.5: leave the objects in place. Deleting them would
    # destroy the evidence needed to work out why they never started.
    echo "   The created objects were LEFT IN PLACE for inspection; nothing was deleted." >&2
    echo "   Inspect with:" >&2
    echo "     kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp | tail -20" >&2
    echo "   Remove them with:" >&2
    echo "     bash scripts/cleanup-monitoring.sh" >&2
    echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
    exit 1
  fi

  sleep "$READY_INTERVAL"
  elapsed=$((elapsed + READY_INTERVAL))
done
echo "  ✅ $ready/$EXPECTED_PODS pods Ready"
echo ""

echo "=== Monitoring Components ==="
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
kubectl get daemonset,deployment,service -n "$NAMESPACE"
echo ""

echo "Scrape endpoints for out-of-cluster Prometheus (reachable only from the"
echo "Monitoring_Security_Group, never from the internet):"
echo "  node-exporter       <node-private-ip>:9100/metrics   (hostPort, one per node)"
echo "  kube-state-metrics  <node-private-ip>:30808/metrics  (NodePort)"
echo ""
echo "Next: bash scripts/provision-monitoring-instance.sh to install Prometheus"
echo "on the out-of-cluster monitoring instance, then confirm every target"
echo "reports up=1 through the SSH tunnel."
echo ""
echo "=== $PHASE: SUCCESS ==="
