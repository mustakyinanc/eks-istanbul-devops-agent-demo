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

# 4. Run a disaster scenario (pick one)
bash scripts/disaster.sh       # Scenario A: CPU saturation + node isolation
bash scripts/disaster-oom.sh   # Scenario B: node-level memory exhaustion

# 5. Open AWS DevOps Agent and enter:
# "We have an active incident in our EKS cluster eks-istanbul.
#  Please investigate and report your findings."

# 6. Cleanup (match the scenario you ran)
bash scripts/cleanup.sh        # after disaster.sh
bash scripts/cleanup-oom.sh    # after disaster-oom.sh
```

## Disaster Scenarios

Two independent scenarios ship with the demo. Run one at a time.

### Scenario A - CPU saturation + node isolation (`disaster.sh`)

Two simultaneous failures:

- `role=isolate` node is cordoned, so it reports `Ready,SchedulingDisabled`
- 6 stress pods land on the `role=stress` node and saturate its CPU

Self-terminating: the pods stop after 600 seconds, so the incident ends on its
own if the demo is abandoned. Trips the `eks-istanbul-high-cpu` alarm in about
2-3 minutes (observed ~50% CPU against a 40% threshold).

### Scenario B - Node-level memory exhaustion (`disaster-oom.sh`)

A harder investigation. Produces a failure chain rather than a single spike:

```
memory hog pods (no memory limit)
  -> node memory exhausted
  -> kernel OOM killer terminates containers (exit code 137, OOMKilled)
  -> kubelet restarts them
  -> OOMKilled again, backoff grows
  -> CrashLoopBackOff, climbing RESTARTS count
```

Three design choices make this **node-level** rather than container-level:

| Choice | Why |
|---|---|
| No `limits.memory` | A cgroup ceiling would kill the container for exceeding its own budget. Without one, allocation continues until the *node* is exhausted. |
| `requests.memory: 64Mi` vs ~900M actual | The kernel scores OOM victims by how far they exceed their request, so the hog pods are killed well before CoreDNS or the CloudWatch agent. |
| `restartPolicy: Always` | Turns a single OOMKill into a visible restart loop with exponential backoff. |

Blast radius is confined to the `role=stress` node. The `role=isolate` node is
left healthy on purpose, giving the investigation a control to compare against.

**Not self-terminating.** Because `restartPolicy` is `Always`, the loop runs
until `cleanup-oom.sh` deletes the pods.

Tunable:

```bash
bash scripts/disaster-oom.sh --pods 5 --bytes 900M
```

Observed results on `c7i.large` nodes (2 vCPU, 3.7 GiB):

| Signal | Value |
|---|---|
| Pods OOMKilled | 5/5, exit code 137 |
| Cumulative restarts | 29 and climbing |
| `node_memory_utilization` | ~61% on the affected node |
| `container_memory_failures_total` | 577 |
| System pods | unaffected |
| Node condition | stayed `Ready` |

## CloudWatch Alarms

| Alarm | Metric | Statistic | Threshold | Scenario |
|---|---|---|---|---|
| `{cluster}-high-cpu` | `node_cpu_utilization` | Average | 40% | A |
| `{cluster}-high-memory` | `node_memory_utilization` | Maximum | 55% | B |
| `{cluster}-container-restarts` | `pod_number_of_container_restarts` | Maximum | 0 | B |

Thresholds are configurable through the `memory_threshold` and
`restart_threshold` Terraform variables.

### Why the memory alarm uses Maximum, not Average

Alarms are dimensioned on `ClusterName`, which aggregates across every node. A
single exhausted node is diluted by the healthy ones: during Scenario B the
affected node sat at ~61% while the idle node sat at ~39%, putting the cluster
**Average** near 50% — below any threshold that would not also fire at idle.
`Maximum` tracks the worst node instead.

This dilution worsens with cluster size, and it is a useful talking point:
cluster-wide averages hide single-node failures.

### Why `MemoryPressure` stays False during Scenario B

The kubelet sets `MemoryPressure` from its housekeeping loop, which samples
every ~10 seconds against an `evictionHard` threshold of `memory.available:
100Mi`. The kernel OOM killer reclaims memory faster than that loop observes
the shortfall, so the node condition often never flips. Evidence lives in
`container_memory_failures_total` and the restart counts instead.

A monitoring setup watching only `MemoryPressure` would miss this incident
entirely.

## Repository Structure

```
├── terraform/
│   ├── main.tf                  # VPC, EKS, Node Groups, IAM, Security Groups
│   ├── variables.tf             # Input variables
│   ├── outputs.tf               # Cluster endpoint, kubeconfig command
│   └── terraform.tfvars.example # Example variables file
├── scripts/
│   ├── setup-alarm.sh           # Install Container Insights + CloudWatch alarm
│   ├── disaster.sh              # Scenario A: node isolation + high CPU
│   ├── cleanup.sh               # Restore after Scenario A
│   ├── disaster-oom.sh          # Scenario B: node-level memory exhaustion
│   └── cleanup-oom.sh           # Restore after Scenario B
├── k8s/
│   ├── stress-pod.yaml          # CPU stress pod definition
│   └── memory-hog-pod.yaml      # Memory exhaustion pod definition
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
