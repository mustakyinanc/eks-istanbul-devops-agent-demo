# Demo Guide

## Overview

This demo shows AWS DevOps Agent investigating a real Kubernetes incident in an EKS cluster whose worker nodes run in the Istanbul Local Zone. The incident is investigated by a single **AWS DevOps Agent Space in us-east-1** that has two telemetry sources attached:

- **EKS + CloudWatch (eu-central-1)**: the `eks-istanbul` cluster, Container Insights and alarms.
- **Grafana Cloud**: attached through the Grafana capability provider (Viewer service account token), fed by an out-of-cluster Prometheus on the Monitoring_Instance.

The EKS cluster and all infrastructure stay in eu-central-1; only the Agent Space is in us-east-1.

```
kubectl (local) ──> EKS control plane (eu-central-1)
                         │
                         ▼
        Worker nodes (Istanbul Local Zone, eu-central-1-ist-1a)
          ├── role=stress   → CPU / memory stress target
          └── role=isolate  → isolation target, runs kube-state-metrics

  Monitoring_Instance (EC2, eu-central-1c, outside the cluster)
    Prometheus scrapes :9100 and :30808 → remote_write → Grafana Cloud
```

**Total setup time:** ~50 minutes
**Demo runtime:** ~15-20 minutes per scenario

---

## Prerequisites

### Tools

```bash
# macOS
brew install awscli kubectl
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

aws --version
terraform --version
kubectl version --client
```

Helm is not required.

### AWS account

- Administrator access, AWS CLI configured (`aws configure`, region `eu-central-1`).
- Verify with `aws sts get-caller-identity`.
- An **existing EC2 key pair** in eu-central-1. Terraform does not create it:

```bash
aws ec2 create-key-pair --region eu-central-1 --key-name eks-istanbul-monitoring \
  --query KeyMaterial --output text > ~/.ssh/eks-istanbul-monitoring.pem
chmod 600 ~/.ssh/eks-istanbul-monitoring.pem
```

### Grafana Cloud

- A free-tier Grafana Cloud stack.
- From the stack's Prometheus details page: the remote_write URL, the user id, and an access policy token with `metrics:write`.

---

## Step 1 - Clone the Repository

```bash
git clone https://github.com/<your-account>/eks-istanbul-devops-agent-demo.git
cd eks-istanbul-devops-agent-demo
```

Run all commands from the repository root unless stated otherwise.

---

## Step 2 - Enable the Istanbul Local Zone (~5 minutes)

1. AWS Console → **EC2** → **Settings** → **Zones**
2. Find `eu-central-1-ist-1a` (Turkey - Istanbul)
3. **Manage** → **Enable Zone Group**
4. Wait for **Enabled**

---

## Step 3 - Deploy Infrastructure (~20 minutes)

```bash
curl ifconfig.me    # your public IP

cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
my_ip        = "x.x.x.x/32"
ssh_key_name = "eks-istanbul-monitoring"
```

```bash
terraform init
terraform apply
cd ..
```

This creates the VPC, EKS cluster, both node groups, add-ons (including Container Insights), the three CloudWatch alarms, and the Monitoring_Instance with its security group and IAM role.

---

## Step 4 - Configure kubectl

```bash
aws eks update-kubeconfig --region eu-central-1 --name eks-istanbul
kubectl get nodes -L role
```

Both nodes should be `Ready`, one with `role=stress` and one with `role=isolate`.

---

## Step 5 - CloudWatch Path (~5 minutes)

```bash
bash scripts/setup-alarm.sh
```

Verify: CloudWatch → Alarms → `eks-istanbul-high-cpu`, `eks-istanbul-high-memory`, `eks-istanbul-container-restarts` are `OK`.

---

## Step 6 - Prometheus / Grafana Path (~10 minutes)

**6.1 In-cluster exporters:**

```bash
bash scripts/setup-monitoring.sh
```

Expect 1 kube-state-metrics pod and 2 node-exporter pods `Ready`.

**6.2 Prometheus on the Monitoring_Instance:**

```bash
export GRAFANA_CLOUD_REMOTE_WRITE_URL='https://prometheus-prod-XX-prod-XX.grafana.net/api/prom/push'
export GRAFANA_CLOUD_USERNAME='<stack user id>'
export GRAFANA_CLOUD_PASSWORD='<access policy token>'
bash scripts/provision-monitoring-instance.sh
```

Expected summary: `node-exporter: 2 up`, `kube-state-metrics: 1 up` (3 targets, all `up=1`). The script is idempotent and masks all credential values in its output.

Optional, to inspect Prometheus locally:

```bash
ssh -i ~/.ssh/eks-istanbul-monitoring.pem -L 9090:127.0.0.1:9090 ec2-user@$(terraform -chdir=terraform output -raw monitoring_public_ip)
# open http://127.0.0.1:9090/targets
```

**6.3 Import the dashboard:** Grafana Cloud → Dashboards → New → Import → upload `k8s/monitoring/grafana-dashboard.json` → select the Grafana Cloud Prometheus data source. Panels: Node CPU usage, Node memory usage, Container restarts.

---

## Step 7 - Set Up AWS DevOps Agent (~10 minutes, manual)

The demo uses one DevOps Agent Space in us-east-1 (see the AWS DevOps Agent documentation for currently supported regions). The monitored resources are in eu-central-1.

**7.1 Create the DevOps Agent Space and attach EKS + CloudWatch (source 1)**

1. AWS Console → DevOps Agent (region `us-east-1`) → **Create Agent Space**, e.g. `eks-istanbul`.
2. **Capabilities** → **Cloud** → primary source: your account, region `eu-central-1`, cluster `eks-istanbul`.
3. **Observability** → add CloudWatch, region `eu-central-1`.

**7.2 Attach Grafana Cloud to the same Agent Space (source 2)**

1. In Grafana Cloud: Administration → Service accounts → create one with the **Viewer** role → generate a token (`glsa_...`). Store it only in your password manager.
2. In DevOps Agent: add a **Grafana capability provider** with your Grafana URL (`https://<stack>.grafana.net`) and the token.
3. Attach the Grafana capability provider to the existing DevOps Agent Space from 7.1. Do not create a second Agent Space.

Both sources of the Agent Space should show a connected status.

---

## Step 8 - Inject a Disaster

### Scenario A - CPU saturation + node isolation

```bash
bash scripts/disaster.sh
kubectl get nodes          # isolate node: Ready,SchedulingDisabled
kubectl get pods -o wide   # all cpu-stress pods on the stress node
```

Panels to watch in Grafana:

- **Node CPU usage**: the `stress` series climbs above 40%.
- **Explore**: `kube_node_spec_unschedulable == 1` for the isolate node.

CloudWatch: `eks-istanbul-high-cpu` goes `OK` → `ALARM` in ~2-3 minutes.

### Scenario B - Node-level memory exhaustion

```bash
bash scripts/disaster-oom.sh
kubectl get pods -o wide   # OOMKilled / CrashLoopBackOff, RESTARTS climbing
```

Panels to watch in Grafana:

- **Node memory usage**: the `stress` series rises (~61%).
- **Container restarts**: the memory-hog pods climb steadily.
- **Explore**: `up{job="node-exporter", node_role="stress"}` may drop to `0` while the node is starved. This gap is recorded by the out-of-cluster Prometheus.

CloudWatch: `eks-istanbul-high-memory` and `eks-istanbul-container-restarts` go to `ALARM`.

---

## Step 9 - Run the Investigation

Start one new investigation manually in the DevOps Agent Space per scenario with exactly this prompt, no hints:

```
We have an active incident in our EKS cluster "eks-istanbul".
Please investigate and report your findings.
```

Let the run complete (~7-10 minutes). Do not add follow-up prompts.

---

## Step 10 - Attribute Findings to Sources

After each scenario, record for every signal which source the finding came from. Values: `detected`, `not detected`, `could not be investigated`.

| Signal | Found via CloudWatch/EKS | Found via Grafana Cloud |
|---|---|---|
| High CPU on stress node (A) | | |
| Node isolation / SchedulingDisabled (A) | | |
| Node memory exhaustion (B) | | |
| Container restart loop / OOMKilled (B) | | |
| Target down (`up=0`) on stress node (B) | | |
| Correct root cause identified | | |
| Time to first finding | | |
| Total investigation time | | |

Optionally compare against the CloudWatch-only baseline in the README ("Key Findings (CloudWatch-only baseline, before Grafana was attached)").

Talking point: in the CloudWatch-only baseline the agent did not detect node isolation, because `SchedulingDisabled` is Kubernetes object state rather than a CloudWatch metric. The Grafana source exports it as `kube_node_spec_unschedulable`. Whether the agent detects it via Grafana Cloud is an open question this demo answers.

---

## Step 11 - Cleanup

```bash
bash scripts/cleanup.sh              # after Scenario A
bash scripts/cleanup-oom.sh          # after Scenario B
```

Between demos, save cost:

```bash
# Scale worker nodes to zero (prints the two commands to run)
terraform -chdir=terraform output -raw scale_to_zero

# Stop the Monitoring_Instance (Prometheus starts again automatically on start)
aws ec2 stop-instances --region eu-central-1 --instance-ids \
  $(aws ec2 describe-instances --region eu-central-1 \
      --filters Name=tag:Name,Values=eks-istanbul-monitoring Name=instance-state-name,Values=running \
      --query 'Reservations[].Instances[].InstanceId' --output text)
```

After a stop/start the public IP changes; re-run `terraform refresh` (or `terraform apply`) before using `terraform output monitoring_public_ip`.

Full teardown:

```bash
bash scripts/cleanup-monitoring.sh
cd terraform && terraform destroy
```

Then, manually: detach the Grafana capability provider from the DevOps Agent Space (us-east-1), remove the provider registration, and revoke the Grafana service account token. Delete the Agent Space itself only if you no longer need it.

---

## Troubleshooting

**terraform apply fails with a subnet error**
→ The Istanbul Local Zone is not enabled (Step 2).

**terraform apply fails with `InvalidKeyPair.NotFound`**
→ `ssh_key_name` must reference an existing key pair in eu-central-1.

**kubectl shows no resources**
```bash
aws eks update-kubeconfig --region eu-central-1 --name eks-istanbul
```

**Container Insights pods not starting**
```bash
aws iam list-attached-role-policies --role-name eks-istanbul-node-role
# CloudWatchAgentServerPolicy must be attached
```

**CloudWatch alarm stays OK after the disaster**
→ Wait 2-3 minutes; check `kubectl get pods -o wide`.

**No data in Grafana panels**
1. Targets: through the SSH tunnel, open `http://127.0.0.1:9090/targets`. Expect 3 targets `up`.
2. If SSH fails: your public IP probably changed. Update `my_ip` in `terraform.tfvars` and run `terraform apply`.
3. If targets are down: check `kubectl -n monitoring get pods -o wide`, and that the cluster security group rules for 9100/30808 from the monitoring security group exist (`terraform plan` shows no drift).
4. If targets are up but Grafana is empty: on the instance, `sudo journalctl -u prometheus -n 50` for remote_write errors (401 = wrong username/token; re-export the variables and re-run `provision-monitoring-instance.sh`).
5. Dashboard data source: re-import the JSON and pick the Grafana Cloud Prometheus data source; set the time range to the last 1 hour.
6. The Monitoring_Instance may be stopped; start it and wait ~1 minute.

**DevOps Agent cannot find the cluster**
→ The Agent Space itself is in us-east-1, but its cloud source must point to region eu-central-1. Verify that, and that IAM allows `eks:DescribeCluster`.

---

## Key Talking Points

- **Istanbul Local Zone**: a real edge scenario; AWS load balancers do not support Local Zones.
- **Out-of-cluster observer**: the Monitoring_Instance survives the incident and records `up=0`. Measured latency to the Local Zone is ~42 ms RTT with scrapes of 0.05-0.27 s.
- **One Agent Space, two sources, one incident**: attribute each finding to CloudWatch/EKS or Grafana Cloud.
- **Cost-aware telemetry**: only 8 metric families leave the account, far below the free-tier series cap.
- **Production gap**: enable EKS control plane logs for full RCA:

```bash
aws eks update-cluster-config --region eu-central-1 --name eks-istanbul \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```
