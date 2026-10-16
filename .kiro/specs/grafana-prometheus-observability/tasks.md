# Implementation Plan

Tasks are split into two phases. Phase 1 creates no DevOps Agent resources and can be validated on its own; Phase 2 adds the Agent integration.

Tasks marked `[M]` are **manual** steps performed by the operator through the Grafana Cloud UI or the AWS Console, because the local AWS CLI has no `devops-agent` command.

Scope note: Grafana alert rules, the webhook Contact_Point, the Notification_Policy and the `devops-agent-payload` template are out of scope (descoped by operator decision). Investigations are started manually in the DevOps Agent console.

The demo must remain fully deployable with `terraform apply` plus the documented scripts and manual steps. README and demo guide are in English. No secret values (access policy tokens, `glsa_` tokens, passwords, the `remote_write` username) appear in any file; placeholders are used instead.

---

## Phase 1 — Metric Collection and Grafana Cloud

- [x] 1. [M] Create the Grafana Cloud stack and collect access details
  - Open a free-tier account on grafana.com and create a stack
  - Record the Grafana_Cloud_Endpoint address (`https://<stack>.grafana.net`)
  - Generate the Prometheus `remote_write` endpoint URL, user ID and password
  - Verify that the Grafana version is 9.0 or later
  - Export the values as environment variables; do not write them to any file
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6_

- [x] 2. Write the in-cluster exporter manifests
- [x] 2.1 Create the namespace and RBAC manifest
  - `k8s/monitoring/00-namespace-rbac.yaml`: `monitoring` namespace
  - ServiceAccount, ClusterRole and ClusterRoleBinding for `kube-state-metrics`
  - The ClusterRole contains only the `get`, `list`, `watch` verbs; it does not contain `create`, `update`, `patch`, `delete`, `deletecollection`
  - _Requirements: 3.6_

- [x] 2.2 Create the node-exporter DaemonSet manifest
  - `k8s/monitoring/10-node-exporter.yaml`: DaemonSet, `hostPort: 9100`
  - **No** node selector based on the `role` label (runs on both nodes)
  - Resources: CPU request 50m, memory request 64Mi, CPU limit 100m, memory limit 128Mi
  - _Requirements: 3.1, 3.2, 3.3_

- [x] 2.3 Create the kube-state-metrics manifest
  - `k8s/monitoring/20-kube-state-metrics.yaml`: Deployment `replicas: 1`, `role=isolate` node selector
  - `NodePort` Service, port 30808
  - Resources: CPU request 50m, memory request 128Mi, CPU limit 200m, memory limit 256Mi
  - Verify that the node schedulability metric (`kube_node_spec_unschedulable`) is emitted
  - _Requirements: 3.4, 3.5, 3.9_

- [x] 3. Add the Monitoring_Instance infrastructure with Terraform
- [x] 3.1 Define variables and the security group
  - `terraform/variables.tf`: `monitoring_instance_type` (default `c7i.large`), `monitoring_disk_size` (default 30), `monitoring_local_retention` (default `24h`), `ssh_key_name`
  - `aws_security_group.monitoring`: inbound 22/tcp only from `var.my_ip`, outbound 443/tcp
  - The Prometheus web port is **not** opened to the public internet
  - _Requirements: 2.12, 2.13, 11.8_

- [x] 3.2 Add exporter rules to the cluster security group
  - Rules on the existing cluster security group for 9100/tcp and 30808/tcp
  - Source is **only** the `aws_security_group.monitoring` ID; `0.0.0.0/0` is not used
  - The two existing rules (80/tcp and 30000-32767/tcp, sourced from `var.my_ip`) are not modified
  - _Requirements: 2.14, 3.8, 11.7, 11.8_

- [x] 3.3 Define the IAM role and the EC2 instance
  - `aws_iam_role.monitoring` + `aws_iam_instance_profile.monitoring`: `ec2:DescribeInstances` permission (for target discovery)
  - `aws_instance.monitoring`: `subnet-0151c4076afb1def8`, `gp3` root disk, public IP
  - `user_data`: only package installation and directory preparation; **no secret values are written**
  - Outputs: private IP, SSH command, Prometheus SSH tunnel command
  - _Requirements: 2.1, 2.2, 2.3_

- [x] 3.4 Validate and apply the Terraform plan
  - Verify in the `terraform plan` output that only new monitoring resources are added
  - Verify that the two existing node groups, the four add-ons and the three CloudWatch alarms are **unchanged**
  - Apply if the plan contains no `destroy`
  - _Requirements: 2.1, 10.1_

- [x] 4. Write the Prometheus provisioning script
- [x] 4.1 Create the Prometheus configuration
  - `k8s/monitoring/prometheus.yml` template: `scrape_interval: 30s`, `scrape_timeout: 10s`
  - `ec2_sd_configs` for both jobs, filter `tag:eks:cluster-name = eks-istanbul`
  - `relabel_configs`: `__meta_ec2_private_ip` → `instance`, `__meta_ec2_tag_eks_nodegroup_name` (regex `ng-istanbul-(.+)`) → `node_role`
  - `remote_write` block: password referenced via `password_file`, queue settings; username supplied as a placeholder (`<GRAFANA_CLOUD_USER>`) at provisioning time
  - _Requirements: 2.4, 2.5, 2.6, 2.7_

- [x] 4.2 Write the Metric_Allowlist filter
  - Allowlist with the `keep` action in `remote_write.write_relabel_configs`
  - Allowed families: `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes`, `kube_pod_container_status_restarts_total`, `kube_node_spec_unschedulable`, `kube_pod_status_phase`, `up`, `node_load1`
  - High-cardinality cAdvisor container metrics are **excluded**
  - Editable from a single place
  - _Requirements: 4.1, 4.2, 4.4, 4.8_

- [x] 4.3 Write the provisioning script
  - `scripts/provision-monitoring-instance.sh`: installs the Prometheus binary and places the configuration
  - Writes the `remote_write` password to `/etc/prometheus/remote_write_password` with `0600` permissions
  - Local retention is set via `--storage.tsdb.retention.time` to the `monitoring_local_retention` value
  - Prometheus listens on `127.0.0.1:9090`
  - The `systemd` unit is installed in the `enabled` state
  - Secret values are read from environment variables and masked in output
  - _Requirements: 2.7, 2.8, 2.13, 11.3, 11.5, 14.13_

- [x] 5. Write the setup and cleanup scripts
- [x] 5.1 Write setup-monitoring.sh
  - Follow the existing repository script pattern: `set -euo pipefail`, numbered steps, ✅/⚠️/❌, `--cluster-name` / `--region`
  - Before applying manifests, check that `kubectl` is available and the context points to the Demo_Cluster
  - If the context is wrong, print the fix command and exit non-zero without applying anything
  - Apply the `k8s/monitoring/` manifests and wait up to 300s for **3 pods** (1 kube-state-metrics + 2 node-exporter) to become `Ready`
  - Report pods that are not ready by name and reason
  - Print the phase name and result on the last line
  - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.10, 13.2, 13.3_

- [x] 5.2 Write cleanup-monitoring.sh
  - Remove all objects in the Monitoring_Namespace, then the namespace and the ClusterRole/ClusterRoleBinding
  - Do **not** touch the CloudWatch add-on or the three alarms
  - Perform no operation on the Grafana Cloud stack, Capability Provider or DevOps_Agent_Space
  - Report missing objects as skipped, continue with remaining steps, exit with code zero
  - _Requirements: 14.6, 14.7, 14.8, 14.9_

- [x] 6. Run and validate the Phase 1 setup
  - Install the in-cluster components with `setup-monitoring.sh`
  - Install Prometheus with `provision-monitoring-instance.sh`
  - Through the SSH tunnel, verify in the Prometheus UI that all targets are `up=1`
  - Measure and record the Monitoring_Subnet → Local Zone scrape latency
  - Result: TCP RTT ~41-45 ms, scrape durations 0.05-0.27 s (well under the 10 s `scrape_timeout`); ICMP is blocked by the security group, so latency was measured over TCP. Risk marked as verified
  - _Requirements: 2.9, 2.15, 2.16, 3.10_

- [x] 7. Deduplicate kube-state-metrics scraping: relabel rule in prometheus.yml keeps only the KSM target on node_role=isolate
  - Observed issue: the KSM NodePort Service uses `externalTrafficPolicy=Cluster`, so port 30808 answered on both nodes; both KSM targets were `up=1` and every KSM series was duplicated under two `instance` labels
  - Fix: `keep` relabel on `__meta_ec2_tag_eks_nodegroup_name` matching `ng-istanbul-isolate` in the `kube-state-metrics` job only
  - Expected targets: 2 node-exporter + 1 kube-state-metrics, all `up=1`
  - _Requirements: 2.9, 2.17, 2.18_

- [ ] 8. [M] Configure the Grafana Cloud dashboard
- [x] 8.1 [M] Create the dashboard
  - Imported from `k8s/monitoring/grafana-dashboard.json`; data is flowing
  - Three separate panels: node CPU utilization, node memory utilization, container restarts
  - CPU and memory panels show one series per node, labeled with the node name
  - Restart panel shows one series per pod
  - CPU and memory panels use percent units, scale 0-100
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5_

- [ ] 8.2 [M] Complete the Phase 1 validation
  - Verify that all three panels show data
  - Verify that the active series count is below the Series_Budget (6,000)
  - _Requirements: 4.3, 4.5, 4.6, 12.6_

---

## Phase 2 — DevOps Agent Integration

- [x] 9. [M] Create the Grafana service account and the Agent registration
- [x] 9.1 [M] Generate a service account token with the Viewer role
  - Create a service account with the `Viewer` role in the Grafana Cloud UI
  - Generate the `glsa_`-prefixed access token and treat it as a secret (never written to any file)
  - _Requirements: 9.4_

- [x] 9.2 [M] Create the Capability Provider registration
  - Create an account-level Grafana provider registration in the AWS Console
  - Grafana URL is the Grafana_Cloud_Endpoint; authentication uses the `glsa_` token
  - The private connectivity option is **not** used
  - Confirm that the endpoint reachability check passes during registration
  - _Requirements: 9.2, 9.3, 9.5, 9.12_

- [x] 9.3 [M] Attach the Grafana capability provider to the existing DevOps Agent Space (us-east-1)
  - The single DevOps_Agent_Space is in `us-east-1`; its existing source is the Demo_Cluster + CloudWatch in `eu-central-1`
  - Attach the Capability Provider as the second telemetry source; no second Agent Space is created
  - Confirm that the Agent can see the Grafana dashboards
  - _Requirements: 9.1, 9.6_

- [ ] 10. Run scenario validation
- [ ] 10.1 Validate the disaster.sh scenario
  - Run `disaster.sh`
  - Observe the node CPU panel: the Stress_Node series rises above the 40 percent reference value within 5 minutes
  - Verify that `kube_node_spec_unschedulable` is 1 for the Isolate_Node
  - Start a manual investigation in the DevOps_Agent_Space and verify that an investigation record is created
  - After `cleanup.sh`, verify that the panels return below the reference values within 10 minutes
  - _Requirements: 5.1, 5.2, 5.11, 5.13, 6.6, 9.8, 12.8_

- [ ] 10.2 Validate the disaster-oom.sh scenario
  - Run `disaster-oom.sh`
  - Observe the node memory panel (affected node above 55 percent) and the container restart panel (restart count increases) within 5 minutes
  - Verify that the Stress_Node `node-exporter` target is recorded as `up=0` during the OOM (**the distinguishing payoff of this design**)
  - Verify that the Isolate_Node target stays `up=1`
  - Start a manual investigation in the DevOps_Agent_Space and verify that an investigation record is created
  - Clean up with `cleanup-oom.sh`
  - _Requirements: 5.3, 5.4, 5.5, 5.12, 6.6, 9.8_

- [ ] 11. [M] Run the source attribution comparison
  - Run a disaster scenario
  - Start one manual investigation in the DevOps_Agent_Space with the fixed prompt, identical character for character across runs
  - Fill in the Comparison_Table for the seven signal rows by source (columns: Found via CloudWatch/EKS, Found via Grafana Cloud); values are `detected` / `not detected` / `could not be investigated`
  - In the node isolation row, record whether `SchedulingDisabled` / `kube_node_spec_unschedulable` is detected via Grafana Cloud (**open question, not a claim**)
  - Optionally compare against the CloudWatch-only baseline table in the README
  - _Requirements: 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8, 10.10_

- [ ] 12. Resilience and lifecycle validation
- [ ] 12.1 Validate the node scaling cycle
  - Scale the worker nodes to zero; verify that in-cluster pods are `Pending` and the data in Grafana Cloud is preserved
  - Scale back to 1 Stress_Node + 1 Isolate_Node
  - Verify that the 3 pods become `Ready` within 300 seconds without manual intervention
  - Verify that Prometheus discovers the new node IPs within 120 seconds (thanks to `ec2_sd_configs`)
  - _Requirements: 14.2, 14.3, 14.4_

- [ ] 12.2 Validate a Monitoring_Instance restart
  - Stop and start the instance
  - Verify that the Prometheus service comes up on its own and resumes scraping within 120 seconds
  - _Requirements: 14.13_

- [ ] 12.3 Validate idempotency and cleanup
  - Run `setup-monitoring.sh` a second time; verify that pod restart counters do not change and no duplicate objects are created
  - Run `cleanup-monitoring.sh`; then run it again with objects missing and verify it exits with code zero
  - After cleanup, verify that the CloudWatch add-on is `ACTIVE` and the three alarms remain defined
  - _Requirements: 12.9, 14.6, 14.7, 14.9_

- [x] 13. Security audit
  - Verify that no version-controlled file contains a `glsa_`-prefixed value, a Grafana Cloud access policy token, the `remote_write` username or password (including base64)
  - Verify that no security group rule carries a `0.0.0.0/0` or `::/0` source
  - Verify that the Prometheus web port is not reachable from the internet
  - Verify that secret values are masked in script output
  - Verify that the `remote_write` password file on the Monitoring_Instance has `0600` permissions
  - _Requirements: 11.2, 11.5, 11.8, 2.13, 15.15_

- [x] 14. Update the documentation (in English)
- [x] 14.1 Update the README
  - Add the Monitoring_Instance (outside the cluster and the Local Zone), the scrape path, the `remote_write` path and the Grafana Cloud boundary to the architecture diagram
  - After the CloudWatch alarm table, add the Grafana_Dashboard panel table (visual reference values only, no alert rules); keep the existing table and its two subheadings
  - Add `k8s/monitoring/` and the new scripts to the repository structure
  - Relabel the existing findings table as the CloudWatch-only baseline (before Grafana was attached) and point to the source attribution table in the demo guide
  - Add a Grafana Cloud account to the prerequisites table; list Helm as "not required"
  - Add a Monitoring_Instance row to the cost table; list the Grafana Cloud free tier as 0
  - Fix the outdated statement presenting `us-east-1` as the only region
  - Confirm the demo deploys end to end with `terraform apply` plus the documented scripts; use placeholders for all secrets
  - _Requirements: 15.2, 15.3, 15.4, 15.5, 15.6, 15.13, 15.14, 15.15, 13.6, 14.11_

- [x] 14.2 Update the demo guide
  - Direct the operator to the AWS DevOps Agent documentation for supported regions; state that the single DevOps_Agent_Space is in `us-east-1` and the monitored resources are in `eu-central-1`; remove the "only `us-east-1`" statement
  - Add the monitoring setup as a numbered step after the `kubectl` context step and before the disaster scenario step
  - For each scenario, add the panels to watch and the expected signals with time bounds, followed by the manual investigation step in the DevOps_Agent_Space
  - Add the Comparison_Table with empty fields ready to be filled in
  - Add the Free_Tier_Limits, Series_Budget and Metric_Allowlist note, and the measured scrape latency
  - Add a "No data in Grafana Cloud panels" item to the troubleshooting section
  - Add the Monitoring_Instance stop step to the cost section
  - _Requirements: 15.1, 15.7, 15.8, 15.9, 15.10, 15.11, 15.13, 15.14, 15.15, 14.12, 2.16_

---

## Notes

**Not applicable criterion:** Requirement 3.7 asks for a Prometheus ServiceAccount and ClusterRole inside the cluster. Because target discovery uses `ec2_sd_configs` and no Kubernetes API authentication is needed, this criterion does not apply. The rationale is recorded in the "Target Discovery: Decision and Rationale" section of `design.md`.

**Descoped (by operator decision):** the former alert-rule task and the webhook task (payload template, Contact_Point, Notification_Policy) have been removed. Requirements 7 and 8 are kept only for traceability.

**Risks:**
- Monitoring_Subnet → Local Zone scrape latency: **verified** in task 6 (TCP RTT ~41-45 ms, scrape durations 0.05-0.27 s)
- Whether the Agent interprets `kube_node_spec_unschedulable` as `SchedulingDisabled`: **not verified**, answered by task 11
