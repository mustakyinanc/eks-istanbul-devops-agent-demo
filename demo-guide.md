# Demo Guide

## Overview

This demo showcases AWS DevOps Agent's ability to investigate a real Kubernetes incident
involving two simultaneous failures in an EKS cluster running on Istanbul Local Zone.

**What you will build:**
```
kubectl (local)
      │
      ▼
EKS Control Plane (Frankfurt - eu-central-1)
      │
      ▼
Worker Nodes (Istanbul Local Zone - eu-central-1-ist-1a)
  ├── Node: role=stress   → CPU stress target
  └── Node: role=isolate  → Isolation target
```

**Total setup time:** ~40 minutes  
**Demo runtime:** ~15 minutes

---

## Prerequisites

### Required Tools

**1. AWS CLI**
```bash
# macOS
brew install awscli

# Verify
aws --version
```

**2. Terraform**
```bash
# macOS
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Verify
terraform --version
```

**3. kubectl**
```bash
# macOS
brew install kubectl

# Verify
kubectl version --client
```

### AWS Account Requirements

- An AWS account with administrator access
- AWS CLI configured:
```bash
aws configure
# Enter: AWS Access Key ID, Secret Access Key, Region: eu-central-1
```

Verify:
```bash
aws sts get-caller-identity
```

---

## Step 1 - Enable Istanbul Local Zone (~5 minutes)

> ⚠️ This step is required. Istanbul Local Zone is not enabled by default.

1. Go to AWS Console → **EC2** → **Settings** (left sidebar) → **Zones**
2. Find `eu-central-1-ist-1a` (Turkey - Istanbul)
3. Click **Manage** → **Enable Zone Group**
4. Wait for status to show **Enabled**

---

## Step 2 - Deploy Infrastructure (~20 minutes)

**2.1 Find your public IP:**
```bash
curl ifconfig.me
```

**2.2 Configure Terraform variables:**
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
region             = "eu-central-1"
cluster_name       = "eks-istanbul"
kubernetes_version = "1.29"
instance_type      = "c7i.large"
my_ip              = "YOUR_IP_HERE/32"   # e.g. "1.2.3.4/32"
```

**2.3 Deploy:**
```bash
terraform init
terraform apply
# Type "yes" when prompted
# This takes ~20 minutes
```

**2.4 Configure kubectl:**
```bash
aws eks update-kubeconfig --region eu-central-1 --name eks-istanbul
```

**2.5 Verify nodes:**
```bash
kubectl get nodes --show-labels
```

Expected output:
```
NAME                                            STATUS   ROLES    AGE   VERSION
ip-10-20-10-xxx.eu-central-1.compute.internal  Ready    <none>   5m    v1.29.x
ip-10-20-10-yyy.eu-central-1.compute.internal  Ready    <none>   5m    v1.29.x
```

Both nodes should be `Ready`. One has `role=stress`, the other `role=isolate`.

---

## Step 3 - Set Up Observability (~5 minutes)

```bash
cd ..
bash scripts/setup-alarm.sh
```

This script:
1. Installs Container Insights addon
2. Waits for metrics to flow to CloudWatch
3. Creates the `eks-istanbul-high-cpu` alarm (threshold: 40%)

**Verify in AWS Console:**
```
CloudWatch → Alarms → eks-istanbul-high-cpu → Status: OK
```

---

## Step 4 - Set Up AWS DevOps Agent (~5 minutes)

> DevOps Agent is currently available in **us-east-1** only.

**4.1 Open DevOps Agent:**
```
AWS Console → Switch region to us-east-1
→ Search "DevOps Agent" → Open
```

**4.2 Create Agent Space:**
1. Click **Create Agent Space**
2. Name: `eks-istanbul-agent`
3. Click **Create**

**4.3 Add EKS cluster as data source:**
1. Go to your Agent Space → **Capabilities** tab
2. Click **Cloud** → **Primary Source** → **Edit**
3. Select your AWS account and region: `eu-central-1`
4. Select cluster: `eks-istanbul`
5. Click **Save**

**4.4 Add CloudWatch as data source:**
1. Still in **Capabilities** tab → **Observability** → **Edit**
2. Add CloudWatch → Region: `eu-central-1`
3. Click **Save**

**4.5 Verify connectivity:**
- Both data sources should show green/connected status

---

## Step 5 - Inject Disaster (~1 minute)

```bash
bash scripts/disaster.sh
```

What happens:
- `role=isolate` node → `SchedulingDisabled` (no new pods can be scheduled)
- 6x stress pods → all land on `role=stress` node → CPU spikes

Verify:
```bash
kubectl get nodes
# role=isolate node should show: Ready,SchedulingDisabled

kubectl get pods -o wide
# All cpu-stress pods should be on the same node
```

---

## Step 6 - Wait for CloudWatch Alarm (~2 minutes)

```
AWS Console → CloudWatch → Alarms → eks-istanbul-high-cpu
```

Wait until status changes: `OK` → `ALARM`

---

## Step 7 - DevOps Agent Investigation

Open AWS DevOps Agent → your Agent Space → **New Investigation**

Enter **exactly** this prompt (no hints):

```
We have an active incident in our EKS cluster "eks-istanbul".
Please investigate and report your findings.
```

Let the agent run (~7-10 minutes). Do not interrupt or provide additional prompts.

---

## Step 8 - Review Findings

### Expected findings:
| Finding | Detected? |
|---|---|
| High CPU on stress node | ✅ |
| ENI churn from VPC CNI | ✅ |
| CloudWatch alarm threshold history | ✅ |
| Cluster remained at 2 nodes | ✅ |
| Node isolation (SchedulingDisabled) | ❌ kubectl access needed |

### Why node isolation is not detected:
DevOps Agent uses CloudWatch and EC2 APIs by default. To detect `SchedulingDisabled` status, it needs kubectl access. This is a known gap and a good talking point in the demo.

### How to enable kubectl access for next demo:
Add DevOps Agent's IAM role to the cluster's `aws-auth` ConfigMap:
```bash
kubectl edit configmap aws-auth -n kube-system
```

Add:
```yaml
mapRoles:
  - rolearn: arn:aws:iam::ACCOUNT_ID:role/DevOpsAgentRole
    username: devops-agent
    groups:
      - system:masters
```

---

## Step 9 - Cleanup

**9.1 Restore cluster:**
```bash
bash scripts/cleanup.sh
```

**9.2 Scale nodes to zero (stop EC2 costs):**
```bash
aws eks update-nodegroup-config --region eu-central-1 \
  --cluster-name eks-istanbul \
  --nodegroup-name ng-istanbul-stress \
  --scaling-config minSize=0,maxSize=2,desiredSize=0

aws eks update-nodegroup-config --region eu-central-1 \
  --cluster-name eks-istanbul \
  --nodegroup-name ng-istanbul-isolate \
  --scaling-config minSize=0,maxSize=2,desiredSize=0
```

**9.3 Destroy all infrastructure (when done):**
```bash
cd terraform
terraform destroy
# Type "yes" when prompted
```

---

## Troubleshooting

**terraform apply fails with subnet error:**
→ Istanbul Local Zone not enabled. Go back to Step 1.

**kubectl get nodes shows no resources:**
```bash
aws eks update-kubeconfig --region eu-central-1 --name eks-istanbul
```

**Container Insights pods not starting:**
→ CloudWatchAgentServerPolicy may be missing from node role. Verify:
```bash
aws iam list-attached-role-policies --role-name eks-istanbul-node-role
```
If missing:
```bash
aws iam attach-role-policy \
  --role-name eks-istanbul-node-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
```

**CloudWatch alarm stays in OK after disaster:**
→ Wait 2-3 minutes, metrics have a delay.
→ Check stress pods are running: `kubectl get pods -o wide`

**DevOps Agent cannot find cluster:**
→ Verify Agent Space data source is set to eu-central-1 region.
→ Verify IAM permissions allow cross-region EKS DescribeCluster.

---

## Key Talking Points

- **Istanbul Local Zone**: Real edge computing scenario — AWS LBs don't support Local Zones
- **Multi-layer investigation**: Kubernetes + EC2 + CloudWatch + VPC ENI all correlated by agent
- **Speed**: Agent completed in ~7 min what would take an engineer 1-2 hours
- **Limitations**: Shows where human oversight is still needed (kubectl access, audit logs)
- **Production gap**: Enable EKS audit logs for full RCA:
```bash
aws eks update-cluster-config \
  --region eu-central-1 \
  --name eks-istanbul \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```
