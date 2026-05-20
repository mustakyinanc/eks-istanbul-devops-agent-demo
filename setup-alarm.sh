#!/bin/bash
# setup-alarm.sh - Install Container Insights and create CloudWatch alarm

set -e

CLUSTER_NAME="eks-istanbul"
REGION="eu-central-1"
ALARM_NAME="eks-istanbul-high-cpu"
THRESHOLD=40

echo "=== EKS Istanbul - Observability Setup ==="
echo ""

# Step 1: Install Container Insights
echo "[1/3] Installing Container Insights addon..."
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name amazon-cloudwatch-observability \
  --region $REGION 2>/dev/null || echo "  ℹ️  Addon already exists, skipping."

echo "  ⏳ Waiting for Container Insights pods to be Ready (this takes ~2 minutes)..."
kubectl wait --for=condition=Ready pods \
  -l app.kubernetes.io/name=cloudwatch-agent \
  -n amazon-cloudwatch \
  --timeout=180s
echo "  ✅ Container Insights running"
echo ""

# Step 2: Wait for metrics to flow
echo "[2/3] Waiting for metrics to flow to CloudWatch (~2 minutes)..."
sleep 120
echo "  ✅ Metrics should be flowing"
echo ""

# Step 3: Create CloudWatch alarm
echo "[3/3] Creating CloudWatch alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name $ALARM_NAME \
  --namespace ContainerInsights \
  --metric-name node_cpu_utilization \
  --dimensions Name=ClusterName,Value=$CLUSTER_NAME \
  --statistic Average \
  --period 60 \
  --threshold $THRESHOLD \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --region $REGION
echo "  ✅ CloudWatch alarm '$ALARM_NAME' created"
echo "     Threshold: ${THRESHOLD}% CPU utilization"
echo ""

echo "=== Setup Complete ==="
echo ""
echo "You can now run: bash scripts/disaster.sh"
