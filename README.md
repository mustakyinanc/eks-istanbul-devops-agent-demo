# EKS Istanbul DevOps Agent Demo

A disaster injection and AI-powered incident investigation demo using **AWS EKS on Istanbul Local Zone** and **AWS DevOps Agent**.

## Architecture

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

> **Note:** AWS Load Balancers (CLB, ALB, NLB) do not support Local Zone subnets.
> NodePort with direct node access is used as a workaround for this demo.

## Quick Start

```bash
# 1. Deploy infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set your public IP
terraform init && terraform apply

# 2. Configure kubectl
aws eks update-kubeconfig --region eu-central-1 --name eks-istanbul

# 3. Set up observability
bash scripts/setup-alarm.sh

# 4. Run disaster
bash scripts/disaster.sh

# 5. Open AWS DevOps Agent and enter:
# "We have an active incident in our EKS cluster eks-istanbul.
#  Please investigate and report your findings."

# 6. Cleanup
bash scripts/cleanup.sh
```

## Repository Structure

```
├── terraform/
│   ├── main.tf                  # VPC, EKS, Node Groups, IAM, Security Groups
│   ├── variables.tf             # Input variables
│   ├── outputs.tf               # Cluster endpoint, kubeconfig command
│   └── terraform.tfvars.example # Example variables file
├── scripts/
│   ├── setup-alarm.sh           # Install Container Insights + CloudWatch alarm
│   ├── disaster.sh              # Inject node isolation + high CPU
│   └── cleanup.sh               # Restore cluster to normal state
├── k8s/
│   └── stress-pod.yaml          # CPU stress pod definition
└── docs/
    └── demo-guide.md            # Step-by-step demo guide
```

## Prerequisites

| Tool | Version |
|---|---|
| AWS CLI | >= 2.x |
| Terraform | >= 1.0 |
| kubectl | any recent |

AWS DevOps Agent must be enabled in **us-east-1**.

## Cost Estimate

| Resource | Cost |
|---|---|
| EKS Control Plane | ~$0.10/hr ($73/mo) |
| 2x c7i.large nodes | ~$0.18/hr each |
| EBS volumes | ~$4/mo |

Scale nodes to zero when not in use — only control plane cost remains.

## Key Findings from Demo

| Finding | Detected by Agent |
|---|---|
| High CPU on stress node | ✅ |
| ENI churn (VPC CNI activity) | ✅ |
| CloudWatch threshold history | ✅ |
| No scaling events | ✅ |
| Node isolation (SchedulingDisabled) | ❌ kubectl access needed |

## Known Limitations of Istanbul Local Zone

- No AWS Load Balancer support (CLB, ALB, NLB)
- No Spot instances
- Limited instance types (c7i, m7i, r7i — no t3)
- Minimum instance size: large

## License

MIT
