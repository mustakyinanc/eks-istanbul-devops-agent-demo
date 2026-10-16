#!/bin/bash
# cleanup-monitoring.sh - Phase 1 teardown: remove the in-cluster metric exporters.
#
# What this does, in order:
#   1. verifies kubectl is executable and that the current context points at
#      the demo cluster, BEFORE anything is deleted
#   2. deletes every Deployment, DaemonSet, Service, ConfigMap, Secret and
#      ServiceAccount in the monitoring namespace
#   3. deletes the monitoring namespace itself and waits for it to go away
#   4. deletes the two cluster-scoped RBAC objects (ClusterRole and
#      ClusterRoleBinding, both named kube-state-metrics)
#   5. confirms the CloudWatch layer is still standing and prints the result
#
# This removes exactly what scripts/setup-monitoring.sh creates, and nothing
# else. The whole run is bounded at 300s (Requirement 14.6).
#
# WHAT THIS DELIBERATELY DOES NOT TOUCH
# -------------------------------------
# CloudWatch (Requirement 14.7). The amazon-cloudwatch namespace, the
# amazon-cloudwatch-observability addon and the three CloudWatch alarms
# (eks-istanbul-high-cpu, eks-istanbul-high-memory, eks-istanbul-container-restarts)
# are left completely alone. They are the OTHER telemetry path in this demo:
# the whole point is to investigate one incident through one DevOps Agent Space
# with two sources and attribute each finding to its source, and deleting the
# CloudWatch side would destroy half of that comparison. Step 4 below only reads them, to prove they survived.
#
# AWS resources (Terraform-managed). The Monitoring_Instance, its security
# group and its IAM role are NOT removed here. They are Terraform state, and
# tearing them down out-of-band would leave that state lying about reality. Use
# `terraform destroy -target=...` for those.
#
# Grafana Cloud, the Grafana Capability Provider and its attachment to the
# DevOps Agent Space in us-east-1 (Requirement 14.8). None of these are touched. They live behind
# a SaaS console and the AWS console, this script speaks only kubectl, and the
# Grafana Cloud stack is deliberately the copy of the incident data that
# outlives the cluster. Removing them is a separate, manually ordered path
# documented in the demo guide: detach the Grafana capability provider from the
# DevOps Agent Space first, then remove the provider, then the stack last.
#
# WHY `set -uo pipefail` AND NOT `-e`
# -----------------------------------
# Same reason as cleanup.sh and cleanup-oom.sh: a cleanup script must survive
# the thing it is cleaning up being half-missing. With `-e`, the first `kubectl
# get` on an object that was already deleted would abort the run and leave the
# remaining objects behind — which is exactly backwards. Every step below
# checks for the object, reports it as skipped when absent, and carries on
# (Requirement 14.9). Missing objects are a normal outcome, not an error, so
# the script still exits 0.
#
# Usage:
#   bash scripts/cleanup-monitoring.sh
#   CLUSTER_NAME=my-cluster REGION=eu-central-1 bash scripts/cleanup-monitoring.sh
#   bash scripts/cleanup-monitoring.sh --cluster-name my-cluster --region eu-central-1
#
# Running it twice is expected and safe: the second run finds nothing, reports
# every object as skipped, and exits 0.
#
# Requirements: 14.6, 14.7, 14.8, 14.9

set -uo pipefail

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
# Requirement 14.6: the whole run is capped at 300s. Namespace deletion is the
# only step that can genuinely take time, so it gets whatever is left of the
# budget after the earlier steps.
TOTAL_TIMEOUT=300
NS_INTERVAL=5
API_TIMEOUT=10s

# The namespaced kinds named by Requirement 14.6. Deleting the namespace would
# take these with it, but they are removed explicitly first so the output names
# what went away rather than hiding it behind one namespace deletion.
NAMESPACED_KINDS=(deployment daemonset service configmap secret serviceaccount)

# The only cluster-scoped objects setup-monitoring.sh creates. Both are named
# kube-state-metrics; the namespace deletion does NOT reach them, which is why
# they need their own step.
CLUSTER_ROLE="kube-state-metrics"
CLUSTER_ROLE_BINDING="kube-state-metrics"

# Kubernetes creates these two in every namespace and recreates them on sight.
# They are not ours to delete: they disappear with the namespace in step 3.
AUTO_MANAGED_OBJECTS="default kube-root-ca.crt"

# Read-only guard that the CloudWatch layer survived (Requirement 14.7).
CLOUDWATCH_NAMESPACE="amazon-cloudwatch"

PHASE="Phase 1 Teardown"
CURRENT_STEP="startup"
START_TS=$SECONDS

# Tracks whether anything went genuinely wrong. Missing objects do NOT set
# this — they are the expected idempotent case.
FAILURES=0
# Counts objects this run actually deleted, purely so the final line can tell
# "removed the stack" apart from "found nothing to remove". Both are success.
DELETED=0

die() {
  echo "❌ $*" >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
}

elapsed() { echo $((SECONDS - START_TS)); }
remaining_budget() { echo $((TOTAL_TIMEOUT - (SECONDS - START_TS))); }

# --- Input validation ---
if [ -z "$CLUSTER_NAME" ] || [ ${#CLUSTER_NAME} -gt 100 ] || ! [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9-]+$ ]]; then
  die "Invalid cluster name '$CLUSTER_NAME'. Expected letters, digits and hyphens, max 100 characters."
fi
if [ -z "$REGION" ] || [ ${#REGION} -gt 30 ]; then
  die "Invalid region '$REGION'. Expected a non-empty value of at most 30 characters."
fi

echo "=== $PHASE: cleanup ==="
echo "  Cluster: $CLUSTER_NAME   Region: $REGION   Namespace: $NAMESPACE"
echo "  Scope:   in-cluster exporters only"
echo "  Leaves untouched: CloudWatch addon + 3 alarms, Monitoring_Instance (Terraform),"
echo "                    Grafana Cloud stack, Capability Provider, DevOps Agent Space attachment"
echo ""

# ---------------------------------------------------------------------------
# [1/4] Prerequisites.
#
# Nothing is deleted until the context is confirmed. This script removes live
# objects, so pointing it at the wrong cluster is worse than pointing
# setup-monitoring.sh at the wrong cluster: an accidental apply can be undone,
# an accidental delete cannot.
# ---------------------------------------------------------------------------
CURRENT_STEP="1/4 prerequisites"
echo "[1/4] Validating prerequisites..."

if ! command -v kubectl >/dev/null 2>&1; then
  echo "❌ Required tool 'kubectl' not found on this machine." >&2
  echo "   This script calls kubectl and nothing else." >&2
  echo "   See the prerequisites table in README.md for the kubectl row." >&2
  echo "   Nothing was deleted." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi
echo "  ✅ kubectl available: $(command -v kubectl)"

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [ -z "$CURRENT_CONTEXT" ]; then
  echo "❌ No current kubectl context is set." >&2
  echo "   Expected a context for cluster '$CLUSTER_NAME'." >&2
  echo "   Fix with:" >&2
  echo "     aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME" >&2
  echo "   Nothing was deleted." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi

# Suffix match rather than a full ARN, for the same reason as
# setup-monitoring.sh: the account id differs per account and hardcoding one
# would tie this script to a single account.
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
  echo "   Nothing was deleted; this cluster is unchanged." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi
echo "  ✅ Context points at '$CLUSTER_NAME': $CURRENT_CONTEXT"

if ! kubectl --request-timeout="$API_TIMEOUT" get --raw /version >/dev/null 2>&1; then
  echo "❌ Cannot reach the Kubernetes API for context '$CURRENT_CONTEXT' within $API_TIMEOUT." >&2
  echo "   Check your AWS credentials and that the cluster endpoint is reachable:" >&2
  echo "     aws eks describe-cluster --name $CLUSTER_NAME --region $REGION" >&2
  echo "   Nothing was deleted." >&2
  echo "=== $PHASE: FAILED ($CURRENT_STEP) ===" >&2
  exit 1
fi
echo "  ✅ Kubernetes API reachable"
echo ""

# ---------------------------------------------------------------------------
# [2/4] Delete the namespaced objects (Requirements 14.6, 14.9).
#
# Each kind is listed first and only deleted if something is there, so an
# already-clean cluster produces a readable "skipped" line per kind instead of
# a NotFound error.
# ---------------------------------------------------------------------------
CURRENT_STEP="2/4 delete namespaced objects"
echo "[2/4] Deleting objects in namespace '$NAMESPACE'..."

if ! kubectl --request-timeout="$API_TIMEOUT" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  # Requirement 14.9: name the missing object, say it was skipped, keep going.
  # The cluster-scoped RBAC in step 4 can outlive the namespace, so there is
  # still real work left after this.
  echo "  ℹ️  Namespace '$NAMESPACE' not present, skipping all namespaced objects"
  echo "      (the ClusterRole and ClusterRoleBinding are cluster-scoped and are still checked in step 4)"
else
  for kind in "${NAMESPACED_KINDS[@]}"; do
    names="$(kubectl --request-timeout="$API_TIMEOUT" get "$kind" -n "$NAMESPACE" \
      -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null || true)"

    # Drop the objects Kubernetes manages itself. Deleting them would succeed
    # and then be instantly undone by the control plane, which is noise, not
    # cleanup. They go away with the namespace in step 3.
    deletable=""
    skipped_auto=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if [[ " $AUTO_MANAGED_OBJECTS " == *" $name "* ]]; then
        skipped_auto="$skipped_auto $name"
      else
        deletable="$deletable $name"
      fi
    done <<< "$names"

    # shellcheck disable=SC2086
    set -- $deletable
    if [ $# -eq 0 ]; then
      if [ -n "$skipped_auto" ]; then
        echo "  ℹ️  No $kind objects of ours in '$NAMESPACE', skipping (cluster-managed:$skipped_auto)"
      else
        echo "  ℹ️  No $kind objects in '$NAMESPACE', skipping"
      fi
      continue
    fi

    if delete_output="$(kubectl delete "$kind" -n "$NAMESPACE" "$@" \
      --wait=false --request-timeout=30s 2>&1)"; then
      echo "  ✅ $kind deletion requested:$deletable"
      DELETED=$((DELETED + $#))
    else
      # A NotFound here means something else removed the object between the
      # list and the delete. That is still a clean outcome, not a failure.
      if printf '%s' "$delete_output" | grep -qi 'not found'; then
        echo "  ℹ️  $kind already gone between list and delete, skipping:$deletable"
      else
        echo "  ⚠️  $kind deletion reported an error:" >&2
        printf '%s\n' "$delete_output" | sed 's/^/       /' >&2
        FAILURES=$((FAILURES + 1))
      fi
    fi
  done
fi
echo ""

# ---------------------------------------------------------------------------
# [3/4] Delete the namespace and wait for it to actually go (Requirement 14.6).
#
# `--wait=false` plus an explicit poll rather than a blocking `kubectl delete`:
# the poll reports progress and keeps the 300s ceiling in one place, and a
# namespace stuck in Terminating is worth naming rather than hanging on.
# ---------------------------------------------------------------------------
CURRENT_STEP="3/4 delete namespace"
echo "[3/4] Deleting namespace '$NAMESPACE'..."

if ! kubectl --request-timeout="$API_TIMEOUT" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "  ℹ️  Namespace '$NAMESPACE' not present, skipping"
else
  if ns_output="$(kubectl delete namespace "$NAMESPACE" --wait=false --request-timeout=30s 2>&1)"; then
    echo "  ✅ Namespace deletion requested"
    DELETED=$((DELETED + 1))
  elif printf '%s' "$ns_output" | grep -qi 'not found'; then
    echo "  ℹ️  Namespace '$NAMESPACE' already gone, skipping"
  else
    echo "  ⚠️  Namespace deletion reported an error:" >&2
    printf '%s\n' "$ns_output" | sed 's/^/       /' >&2
    FAILURES=$((FAILURES + 1))
  fi

  # Deleting a namespace cascades to everything in it, so this wait also
  # confirms step 2 landed.
  while kubectl --request-timeout="$API_TIMEOUT" get namespace "$NAMESPACE" >/dev/null 2>&1; do
    budget="$(remaining_budget)"
    if [ "$budget" -le 0 ]; then
      ns_phase="$(kubectl get namespace "$NAMESPACE" -o go-template='{{.status.phase}}' 2>/dev/null || echo Unknown)"
      echo "  ⚠️  Namespace '$NAMESPACE' is still $ns_phase after $(elapsed)s (budget ${TOTAL_TIMEOUT}s)." >&2
      echo "      A namespace wedged in Terminating is usually a finalizer on a remaining object." >&2
      echo "      Inspect with:" >&2
      echo "        kubectl get all -n $NAMESPACE" >&2
      echo "        kubectl get namespace $NAMESPACE -o jsonpath='{.spec.finalizers}'" >&2
      FAILURES=$((FAILURES + 1))
      break
    fi
    echo "  ⏳ Namespace still terminating ($(elapsed)s/${TOTAL_TIMEOUT}s)"
    sleep "$NS_INTERVAL"
  done

  if ! kubectl --request-timeout="$API_TIMEOUT" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "  ✅ Namespace '$NAMESPACE' removed ($(elapsed)s)"
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# [4/4] Delete the cluster-scoped RBAC (Requirements 14.6, 14.9).
#
# These are the only objects setup-monitoring.sh creates outside the namespace,
# so deleting the namespace does not reach them. Left behind they would be
# orphaned cluster-wide read permission bound to a ServiceAccount that no
# longer exists.
# ---------------------------------------------------------------------------
CURRENT_STEP="4/4 delete cluster-scoped RBAC"
echo "[4/4] Deleting cluster-scoped RBAC objects..."

delete_cluster_scoped() {
  local kind="$1" name="$2" output
  if ! kubectl --request-timeout="$API_TIMEOUT" get "$kind" "$name" >/dev/null 2>&1; then
    echo "  ℹ️  $kind/$name not present, skipping"
    return
  fi
  if output="$(kubectl delete "$kind" "$name" --wait=false --request-timeout=30s 2>&1)"; then
    echo "  ✅ $kind/$name deleted"
    DELETED=$((DELETED + 1))
  elif printf '%s' "$output" | grep -qi 'not found'; then
    echo "  ℹ️  $kind/$name already gone, skipping"
  else
    echo "  ⚠️  $kind/$name deletion reported an error:" >&2
    printf '%s\n' "$output" | sed 's/^/       /' >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# Binding before role: the binding is the thing that actually grants the
# permission, so removing it first means there is no moment where a live
# binding points at a role that is on its way out.
delete_cluster_scoped clusterrolebinding "$CLUSTER_ROLE_BINDING"
delete_cluster_scoped clusterrole "$CLUSTER_ROLE"
echo ""

# ---------------------------------------------------------------------------
# Verify the CloudWatch layer survived (Requirement 14.7).
#
# Read-only on purpose. This is the second telemetry path the demo compares
# against, so the useful thing a teardown script can do about it is prove it
# was not collateral damage.
# ---------------------------------------------------------------------------
echo "=== CloudWatch layer (left untouched, read-only check) ==="
if kubectl --request-timeout="$API_TIMEOUT" get namespace "$CLOUDWATCH_NAMESPACE" >/dev/null 2>&1; then
  cw_total=$(kubectl get pods -n "$CLOUDWATCH_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  cw_running=$(kubectl get pods -n "$CLOUDWATCH_NAMESPACE" --no-headers 2>/dev/null \
    | awk '{split($2, a, "/"); if (a[2] != "" && a[1] == a[2] && a[1] != "0" && $3 == "Running") c++} END {print c + 0}')
  if [ "$cw_total" -gt 0 ] && [ "$cw_running" -eq "$cw_total" ]; then
    echo "  ✅ $cw_running/$cw_total pods in '$CLOUDWATCH_NAMESPACE' still Running"
  else
    # Not attributable to this script — nothing above writes to this namespace.
    echo "  ⚠️  $cw_running/$cw_total pods in '$CLOUDWATCH_NAMESPACE' Running; this script did not modify them"
  fi
  kubectl get pods -n "$CLOUDWATCH_NAMESPACE" --no-headers 2>/dev/null | sed 's/^/     /'
else
  echo "  ℹ️  Namespace '$CLOUDWATCH_NAMESPACE' not present; nothing here was modified either way"
fi
echo ""
echo "  The amazon-cloudwatch-observability addon and the three CloudWatch alarms"
echo "  (eks-istanbul-high-cpu, eks-istanbul-high-memory, eks-istanbul-container-restarts)"
echo "  were not read for modification and not changed. Confirm independently with:"
echo "    aws eks describe-addon --cluster-name $CLUSTER_NAME --region $REGION \\"
echo "      --addon-name amazon-cloudwatch-observability --query 'addon.status'"
echo "    aws cloudwatch describe-alarms --region $REGION \\"
echo "      --alarm-names eks-istanbul-high-cpu eks-istanbul-high-memory eks-istanbul-container-restarts \\"
echo "      --query 'MetricAlarms[].AlarmName'"
echo ""

echo "=== Remaining in-cluster monitoring objects ==="
leftover=0
if kubectl --request-timeout="$API_TIMEOUT" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "  ⚠️  Namespace '$NAMESPACE' still exists"
  leftover=$((leftover + 1))
else
  echo "  ✅ Namespace '$NAMESPACE': gone"
fi
for pair in "clusterrole/$CLUSTER_ROLE" "clusterrolebinding/$CLUSTER_ROLE_BINDING"; do
  kind="${pair%%/*}"; name="${pair#*/}"
  if kubectl --request-timeout="$API_TIMEOUT" get "$kind" "$name" >/dev/null 2>&1; then
    echo "  ⚠️  $kind/$name still exists"
    leftover=$((leftover + 1))
  else
    echo "  ✅ $kind/$name: gone"
  fi
done
echo ""

echo "Still in place by design: Monitoring_Instance and its security group and IAM"
echo "role (Terraform — remove with terraform destroy -target), the Grafana Cloud"
echo "stack, the Grafana Capability Provider and its DevOps Agent Space attachment"
echo "(console-only, and the Grafana Cloud copy of the incident data is the point)."
echo ""
echo "Re-run Phase 1 with: bash scripts/setup-monitoring.sh"
echo ""

# Requirement 14.9: missing objects are not an error, so a run that found
# nothing to do still ends here with exit 0. Only a genuine failure — a delete
# the API rejected, or a namespace still standing — is reported as one.
if [ "$FAILURES" -gt 0 ] || [ "$leftover" -gt 0 ]; then
  echo "=== $PHASE: FAILED ($FAILURES error(s), $leftover object(s) remaining, $(elapsed)s) ===" >&2
  exit 1
fi

if [ "$DELETED" -eq 0 ]; then
  # The idempotent second run: nothing was there to remove, which is the
  # desired end state rather than a problem.
  echo "=== $PHASE: SUCCESS (nothing to remove, already clean; $(elapsed)s, CloudWatch untouched) ==="
else
  echo "=== $PHASE: SUCCESS ($DELETED object(s) removed in $(elapsed)s, CloudWatch untouched) ==="
fi
