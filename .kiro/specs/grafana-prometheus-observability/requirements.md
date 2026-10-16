# Requirements Document

## Introduction

This feature moves the metrics of the `eks-istanbul` cluster entirely outside the cluster: only thin, stateless exporters (node-exporter, kube-state-metrics) run inside the cluster, while Prometheus runs on an independent EC2 instance in Frankfurt, outside both the Local Zone and the cluster, and scrapes those exporters from within the VPC. Prometheus keeps the metrics in its own local time series store and also forwards them via `remote_write` to a **Grafana Cloud** stack outside the AWS account. Dashboards and long-term retention live on the Grafana Cloud side. AWS DevOps Agent reads this Grafana Cloud instance over public HTTPS as a telemetry source. Grafana alert rules and the webhook-based automatic investigation trigger have been descoped by operator decision (Requirements 7 and 8); investigations are started manually by the Demo_Operator in the DevOps_Agent_Space.

The demo's current observability layer consists of CloudWatch Container Insights and three CloudWatch alarms. This feature does not remove the CloudWatch layer; it adds a second, independent telemetry path next to it. The incident is investigated through a single DevOps_Agent_Space that has two telemetry sources attached: (a) the Demo_Cluster and CloudWatch (Container Insights, alarms) in `eu-central-1`, and (b) the Grafana_Cloud_Stack through the Capability_Provider. The DevOps_Agent_Space is in the `us-east-1` (N. Virginia) region; the Demo_Cluster and the Monitoring_Instance are in the `eu-central-1` (Frankfurt) region, and the Grafana_Cloud_Stack is in the `prod-eu-west-2` region. This cross-region placement is deliberate and does not cause problems: the Agent reads Grafana Cloud over the public internet and reads CloudWatch data cross-region. Attributing each finding of one investigation to the source it came from is a deliberate narrative point of the demo.

### Scope Changes (descoped by operator decision)

1. **Grafana alert rules removed.** The CPU, memory and restart alert rules (former Requirement 7), as well as the webhook contact point, notification policy, `devops-agent-payload` template and automatic investigation trigger (former Requirement 8), are out of scope. Scenario observations are made through the Grafana_Dashboard panels (Requirement 6), and investigations are started manually (Requirement 10).
2. **Agent Space region is `us-east-1`.** There is exactly one DevOps_Agent_Space, in `us-east-1`. The Demo_Cluster and all infrastructure remain in `eu-central-1`. No separate Agent Space exists for Grafana or for CloudWatch.
3. **Kube_State_Metrics scraped once.** Kube_State_Metrics series are collected exactly once (Requirements 2.17, 2.18).
4. **Completed state:** The three-panel Grafana_Dashboard has been imported from `k8s/monitoring/grafana-dashboard.json` and is showing data; the service account with the `Viewer` role, and the Capability_Provider have been created, the Capability_Provider has been attached to the existing DevOps_Agent_Space, and the Agent can see the Grafana dashboards.
5. **Rationale:** Automatic alert-driven investigations add configuration surface (alert rules, contact point, notification policy, payload template, webhook credentials) without changing what the comparison measures. Starting one investigation manually per scenario with a fixed prompt keeps the source attribution directly comparable across runs.

### Evolution of the Architecture and Final Rationale

This design went through two corrections worth recording. Both are closed decisions and are not open for re-discussion.

1. **First draft (rejected):** Prometheus and Grafana both ran inside the cluster, on the `role=isolate` node, with `emptyDir` storage. This approach was rejected: if the observability layer lives inside the cluster whose failures it investigates, it dies with the cluster and the incident data is lost. **The observer must not share the fate of the observed** — this is the core insight of the design.
2. **Second draft (works but heavy):** Prometheus and Grafana were moved to a separate EC2 host in Frankfurt and exposed to the Agent via a VPC Lattice-based private connection. It was a working solution; however, it required a self-signed TLS certificate, a PEM chain upload, Subject Alternative Name matching, a resource gateway, and unsupported availability zone constraints.
3. **Third draft (lean but carried a trade-off):** Storage and dashboards were moved to Grafana Cloud, and only a stateless collector was left inside the cluster. The private connection and certificate burden disappeared; however, because the collector remained inside the failure domain, the fact that targets went down could not be recorded when the `role=isolate` node failed.
4. **Final decision (this document):** **Out-of-cluster Prometheus + Grafana Cloud.** Prometheus runs on an independent EC2 instance in Frankfurt and scrapes the exporters from within the VPC; Grafana Cloud takes over dashboards and long-term retention. This combination eliminates the trade-off of the third draft: because scraping is done from outside the cluster, a target going down (`up` value 0) is recorded, and this record becomes a distinguishing signal for the investigation. The private connection and certificate burden does not return either, because the Agent reads the public HTTPS endpoint of Grafana Cloud.

### Final Architecture

```
Grafana Cloud (SaaS — prod-eu-west-2, public HTTPS endpoint, valid public certificate)
  ├── Prometheus-compatible metrics store (Grafana Cloud Metrics, long-term retention)
  ├── Grafana dashboards (3 panels: node CPU, node memory, container restarts)
  └── Read by DevOps Agent (DevOps_Agent_Space, us-east-1, Grafana source) over public HTTPS — NO PRIVATE CONNECTION
        (no alert rules / webhook; investigations are started manually by the Demo_Operator)
        ↑ remote_write (outbound connection)
Monitoring_Instance (independent EC2, Frankfurt / eu-central-1c / euc1-az1, 10.20.2.0/24)
  ├── Prometheus (compute optimized instance type)
  └── Local_TSDB (local copy, remains writable during a disaster)
        ↓ scrape (intra-VPC, over private IP)
EKS worker nodes (Istanbul Local Zone / eu-central-1-ist-1a, 10.20.10.x)
  ├── node-exporter (DaemonSet, BOTH nodes — including Stress_Node)
  └── kube-state-metrics (role=isolate; NodePort 30808, scraped as a single target via Isolate_Node only)
```

The Monitoring_Instance is outside both the Demo_Cluster and the Local_Zone; none of the injected disaster scenarios touch it.

### What Has Been Eliminated

The following are closed decisions, not open questions:

- No VPC Lattice private connection, resource gateway or ENIs; the Agent reads the public HTTPS endpoint of Grafana Cloud.
- The unsupported availability zone ID constraint (`euc1-az2` and similar) is **irrelevant**; the Monitoring_Subnet is chosen for network proximity to the cluster, not for VPC Lattice.
- The unverified risk of whether the Local Zone subnet supports VPC Lattice has been **eliminated**.
- No self-signed certificate, PEM chain upload, Subject Alternative Name matching, internal DNS name or Route 53 record; Grafana Cloud presents a valid public certificate. The HTTPS issue encountered in the Agent console is therefore eliminated: AWS's own documentation uses the `https://myinstance.grafana.net` format as the example Grafana URL.
- The Kubernetes persistent volume risk (the EBS CSI driver not being installed; the only StorageClass, `gp2`, using the legacy `kubernetes.io/aws-ebs` provisioner, and it being unknown whether it would provision volumes on Kubernetes 1.33) has been **eliminated**; Prometheus storage is on the local disk of the Monitoring_Instance, and long-term retention is in Grafana Cloud. No PersistentVolumeClaim is created on the cluster.
- The trade-off of the in-cluster collector remaining inside the failure domain has been **eliminated**; scraping is now done from outside the cluster.

### Accepted Trade-offs

These are deliberately accepted trade-offs that are not hidden, and they are written down as explicit requirements below:

1. **The Monitoring_Instance is in the same VPC.** It is outside the Demo_Cluster and the Local_Zone, and is therefore not affected by the injected disaster scenarios. However, a VPC-level outage could affect both the cluster and the Monitoring_Instance; in that case, the copy in Grafana Cloud continues to serve the incident data.
2. **Monitoring incurs additional AWS cost.** The Monitoring_Instance keeps accruing charges even when the worker nodes are scaled to zero; it must be stopped outside the demo.
3. **Grafana Cloud free tier limits:** 10,000 active metric series, 14 days of retention, 3 active users. cAdvisor alone can produce more than 5,000 series, node-exporter about 3,000 series for two nodes, and kube-state-metrics 2,000-3,000 series. Therefore, **metric filtering (an allowlist made up of the series the demo actually needs) is mandatory from the start** and cannot be deferred.
4. **Metrics leave the AWS account.** In this demo, the data sent consists only of node names and resource usage values, so this is acceptable. Nevertheless, it is an explicit requirement that no sensitive data is sent and that credentials and tokens are never written to any output.
5. **The demo narrative changes:** from "connecting our self-hosted observability without exposing it" to "connecting third-party SaaS observability to the Agent". This change is noted in the comparison and documentation requirements.

### Existing Documentation Errors to Fix

`docs/demo-guide.md` states that DevOps Agent is available only in the `us-east-1` region, and `README.md` states that the Agent must be enabled in the `us-east-1` region. These statements misrepresent the region constraint. As part of this work, the documents no longer assert a fixed region list; instead, the README and the Demo_Guide tell the operator to check the AWS DevOps Agent documentation for the currently supported regions, and they explicitly state that **the single DevOps_Agent_Space used in this demo is in the `us-east-1` region, while the Demo_Cluster and all monitored resources are in the `eu-central-1` region**. The cross-region placement is not a problem, because the Agent reads Grafana Cloud over the public internet and reads CloudWatch data cross-region.

## Glossary

- **Demo_Operator**: The engineer who runs the demo end to end from their own local workstation.
- **Demo_Cluster**: The EKS cluster named `eks-istanbul`, created with Terraform, whose control plane is in the `eu-central-1` region, running Kubernetes 1.33, with status `ACTIVE`.
- **Demo_Cluster_Context**: The `kubectl` context value that targets the Demo_Cluster: `arn:aws:eks:eu-central-1:<ACCOUNT_ID>:cluster/eks-istanbul`.
- **Local_Zone**: The `eu-central-1-ist-1a` AWS Local Zone that hosts the demo worker nodes.
- **Worker_Node**: A `c7i.large` worker node running in the Local_Zone; allocatable resources per node are 1930m CPU, 3215884Ki memory and 29 pods.
- **Stress_Node**: The Worker_Node carrying the `role=stress` label; the target of CPU and memory load injection.
- **Isolate_Node**: The Worker_Node carrying the `role=isolate` label; the node cordoned by `disaster.sh` and the node that hosts Kube_State_Metrics.
- **Monitoring_Namespace**: The Kubernetes namespace named `monitoring` into which the in-cluster monitoring components are deployed.
- **Grafana_Cloud**: The hosted (SaaS) Grafana service operated by Grafana Labs, outside the AWS account.
- **Grafana_Cloud_Stack**: The Grafana_Cloud stack created for this demo in the `prod-eu-west-2` region; it comprises the metrics store, the dashboards and the user interface.
- **Grafana_Cloud_Endpoint**: The public HTTPS address of the Grafana_Cloud_Stack; it has the format `https://<stack-name>.grafana.net` and presents a valid public certificate.
- **Grafana_Cloud_Metrics**: The Prometheus-compatible metrics store inside the Grafana_Cloud_Stack.
- **Remote_Write_Endpoint**: The Prometheus `remote_write` HTTPS endpoint that the Grafana_Cloud_Stack publishes for Prometheus.
- **Remote_Write_Credentials**: The user ID and access token pair, generated per stack, used to authenticate to the Remote_Write_Endpoint.
- **Free_Tier_Limits**: The Grafana_Cloud free tier limits: 10,000 active metric series, 14 days of retention and 3 active users.
- **Retention_Period**: The period for which Grafana_Cloud_Metrics retains metrics; it is 14 days on the free tier and is managed by Grafana_Cloud.
- **Series_Budget**: The upper bound on the number of active series expected on Grafana_Cloud_Metrics after the Metric_Allowlist is applied.
- **Metric_Allowlist**: The allowlist that restricts, by name, the metric families Prometheus sends to the Remote_Write_Endpoint.
- **Monitoring_Instance**: The independent EC2 instance hosting Prometheus, running in Frankfurt in the `eu-central-1c` (`euc1-az1`) subnet, outside the Demo_Cluster and the Local_Zone.
- **Monitoring_Subnet**: The subnet `subnet-0151c4076afb1def8` (`eu-central-1c`, `euc1-az1`, CIDR `10.20.2.0/24`) in which the Monitoring_Instance resides.
- **Monitoring_Security_Group**: The security group attached to the Monitoring_Instance; it allows outbound HTTPS traffic to Grafana_Cloud and restricts inbound traffic to the operator IP address only.
- **Prometheus**: The metrics collector running on the Monitoring_Instance that scrapes the Worker_Node exporters, maintains a local time series database (TSDB) and forwards metrics to the Remote_Write_Endpoint.
- **Local_TSDB**: Prometheus's local time series store on the Monitoring_Instance; it remains writable without interruption during disaster scenarios.
- **Local_Retention_Period**: The period for which the Local_TSDB retains metrics on the Monitoring_Instance.
- **Node_Exporter**: The DaemonSet component that runs on each Worker_Node and emits node-level CPU and memory metrics.
- **Kube_State_Metrics**: The component that emits Kubernetes object states as metrics, in this scope including container restart counts and node schedulability status.
- **Grafana_Dashboard**: The dashboard defined in the Grafana_Cloud_Stack that shows the node CPU, node memory and container restart signals.
- **KSM_Scrape_Target**: The single target Prometheus scrapes for Kube_State_Metrics: NodePort 30808 on the private IP address of the Worker_Node labeled `node_role=isolate`. The `node_role` label is derived from the EKS-managed EC2 tag `eks:nodegroup-name=ng-istanbul-isolate`.
- ~~Grafana_Alert_Rules, CPU_Alert, Memory_Alert, Restart_Alert, Contact_Point, Agent_Payload_Template, Notification_Policy~~: *Out of scope — descoped by operator decision.* These terms are listed for traceability only and are not used in any active requirement.
- **Manual_Investigation**: An investigation started manually by the Demo_Operator in the DevOps_Agent console through the DevOps_Agent_Space.
- **DevOps_Agent**: The AWS DevOps Agent service.
- **Agent_Regions**: The set of regions in which DevOps_Agent is currently available. This document does not assert a fixed list; the README and the Demo_Guide direct the operator to the AWS DevOps Agent documentation for the currently supported regions.
- **DevOps_Agent_Space**: The single AWS DevOps Agent Space used in this demo, in the `us-east-1` (N. Virginia) region. It has two telemetry sources attached: (a) the Demo_Cluster and CloudWatch (Container Insights, alarms) in `eu-central-1`, and (b) the Grafana_Cloud_Stack through the Capability_Provider (Viewer Service_Account_Token).
- **Capability_Provider**: The Grafana provider registration created at the account level in the DevOps_Agent console; it is created before being attached to the DevOps_Agent_Space.
- **Service_Account_Token**: The Grafana service account access token, starting with the `glsa_` prefix and having the `Viewer` role, that DevOps_Agent uses to authenticate to the Grafana API.
- **Monitoring_Secret**: The Kubernetes Secret object that holds the Remote_Write_Credentials values.
- **Monitoring_Manifests**: The plain Kubernetes manifest files that install the in-cluster monitoring components, kept under version control in the repository under `k8s/monitoring/`.
- **Monitoring_Setup_Script**: The script that installs the in-cluster monitoring components and waits for them to become ready.
- **Monitoring_Cleanup_Script**: The script that removes the in-cluster monitoring components from the Demo_Cluster.
- **Demo_Guide**: The `docs/demo-guide.md` document that guides the Demo_Operator step by step.
- **README**: The `README.md` document at the repository root.
- **Comparison_Table**: The source attribution table that records, for one investigation in the DevOps_Agent_Space and per signal row, whether the finding was found via the CloudWatch/EKS source and whether it was found via the Grafana Cloud source.
- **Comparison_Values**: The closed set of values that may be used in Comparison_Table cells: `detected`, `not detected`, `could not be investigated`.

## Requirements

### Requirement 1: Grafana Cloud Stack Setup

**User Story:** As a Demo_Operator, I want the metrics store and the Grafana interface to be hosted outside my AWS account, so that I can access incident data even when the cluster fails.

#### Acceptance Criteria

1. THE Grafana_Cloud_Stack SHALL be created as a single stack on the Grafana_Cloud free tier
2. THE Grafana_Cloud_Stack SHALL publish a Grafana_Cloud_Endpoint in the format `https://<stack-name>.grafana.net` that presents a valid public certificate
3. THE Grafana_Cloud_Endpoint SHALL respond over HTTPS with at least TLS 1.2
4. THE Grafana_Cloud_Stack SHALL provide Grafana version 9.0 or later, because the DevOps_Agent integration cannot execute data source operations on versions earlier than 9.0
5. THE Grafana_Cloud_Stack SHALL generate a Remote_Write_Endpoint address for Prometheus and the associated Remote_Write_Credentials values
6. THE Demo_Guide SHALL provide a step to record the region in which the Grafana_Cloud_Stack was created and the Grafana_Cloud_Endpoint address
7. THE Demo_Guide SHALL state the Free_Tier_Limits values (10,000 active metric series, 14 days of retention, 3 active users)
8. THE Retention_Period SHALL be managed by Grafana_Cloud and applied as 14 days on the free tier; no persistent metric storage volume is created on the Demo_Cluster
9. IF the number of active users on the Grafana_Cloud_Stack has reached 3 and a new user is to be added, THEN THE Demo_Guide SHALL provide a troubleshooting step stating the free tier user limit and that an existing user must be removed

### Requirement 2: Out-of-Cluster Monitoring Instance and Prometheus

**User Story:** As a Demo_Operator, I want Prometheus to run completely outside the cluster and the Local Zone, so that during a disaster data collection continues and the fact that targets went down is recorded.

#### Acceptance Criteria

1. THE Monitoring_Instance SHALL be created as an independent EC2 instance that is not a node of the Demo_Cluster, inside the Monitoring_Subnet and outside the Local_Zone
2. THE Monitoring_Instance SHALL use a compute optimized instance type, and this type SHALL be offered in the `eu-central-1c` availability zone in which the Monitoring_Subnet resides
3. THE Monitoring_Instance SHALL be managed with Terraform and defined as part of the existing Terraform configuration in the repository
4. THE Prometheus SHALL run on the Monitoring_Instance and scrape the Node_Exporter and Kube_State_Metrics targets on the Worker_Nodes over intra-VPC private IP addresses
5. THE Prometheus SHALL apply a scrape interval of 30 seconds or less and a scrape timeout of at most 10 seconds
6. THE Prometheus SHALL store the scraped metrics in the Local_TSDB and forward the same metrics to the Remote_Write_Endpoint over HTTPS
7. THE Prometheus SHALL read the Remote_Write_Credentials values from a configuration source on the Monitoring_Instance that is not included in the repository
8. THE Local_Retention_Period SHALL be configured as at least 24 hours, because long-term retention is provided on the Grafana_Cloud side and the local store only guarantees continuity during a disaster
9. WHEN the Prometheus service starts, THE Prometheus SHALL, within 120 seconds, produce an `up` value for every configured scrape target (one Node_Exporter target per Worker_Node and exactly one KSM_Scrape_Target) and complete at least one successful write request to the Remote_Write_Endpoint; the expected number of targets on a healthy cluster is 3 (2 Node_Exporter + 1 Kube_State_Metrics), and all three carry an `up` value of 1
10. IF the Remote_Write_Endpoint becomes temporarily unreachable, THEN THE Prometheus SHALL keep the unsent samples in its own queue, retry with increasing backoff, continue writing to the Local_TSDB without interruption, and keep running without restarting the service
11. IF the Remote_Write queue becomes full, THEN THE Prometheus SHALL drop the oldest samples, emit the number of dropped samples as its own metric, and continue scraping
12. THE Monitoring_Security_Group SHALL allow outbound HTTPS traffic to Grafana_Cloud and, for inbound traffic, allow only SSH connections from the operator IP address (`/32` source)
13. THE Monitoring_Security_Group SHALL NOT allow any traffic from the public internet to the port on which the Prometheus interface listens; the Demo_Operator accesses this interface only through an SSH tunnel
14. THE Demo_Cluster security group SHALL allow access to the Node_Exporter and Kube_State_Metrics ports through a rule that references the Monitoring_Security_Group as its source, and this rule SHALL NOT use `0.0.0.0/0` as its source
15. IF Prometheus cannot reach a Worker_Node target through the Monitoring_Subnet, THEN THE Demo_Guide SHALL provide a troubleshooting step that includes checking the Demo_Cluster security group rule and the routing between the Monitoring_Subnet and the Local_Zone subnet
16. THE Demo_Guide SHALL state the measured scrape latency between the Monitoring_Subnet and the Local_Zone subnet (TCP RTT about 41-45 ms, scrape durations 0.05-0.27 s, well below the 10 s `scrape_timeout`; ICMP is blocked by the security group, so latency is measured over TCP) and record this former risk as verified
17. THE Prometheus SHALL collect Kube_State_Metrics series exactly once; the Kube_State_Metrics scrape job targets only the KSM_Scrape_Target on the Worker_Node labeled `node_role=isolate` and does not add the NodePort 30808 address of the other Worker_Nodes to its target list. The keep rule matches the EKS-managed EC2 tag `eks:nodegroup-name=ng-istanbul-isolate`, because the Kubernetes node label `role=isolate` is not visible to `ec2_sd_configs`; the `node_role` label is derived from that same tag (observed problem: because of `externalTrafficPolicy=Cluster`, NodePort 30808 responds on both nodes, both targets return an `up` value of 1, and the same Kube_State_Metrics series arrive twice with different `instance` labels, causing double counting and wasting the Series_Budget)
18. WHEN Prometheus runs without interruption for 15 minutes, THE Grafana_Cloud_Metrics SHALL report each `kube_pod_container_status_restarts_total` series (for the same `namespace`, `pod` and `container` labels) with a single `instance` label value

### Requirement 3: In-Cluster Exporters

**User Story:** As a Demo_Operator, I want the metrics of both nodes to be collected, so that I also have the data of the node targeted by the disaster.

#### Acceptance Criteria

1. THE Monitoring_Manifests SHALL deploy Node_Exporter as a DaemonSet such that exactly 1 pod runs on each Worker_Node and 2 pods run in total in the cluster
2. THE Monitoring_Manifests SHALL NOT define any node selector based on the `role` label for Node_Exporter, so that the Stress_Node is also covered
3. THE Monitoring_Manifests SHALL define, for the Node_Exporter pods, a CPU request of at most 100m, a memory request of at most 128Mi and a memory limit of at most 128Mi
4. THE Monitoring_Manifests SHALL deploy Kube_State_Metrics in the Monitoring_Namespace as a Deployment with `replicas: 1` and the `role=isolate` node selector
5. THE Monitoring_Manifests SHALL define, for the Kube_State_Metrics pod, a CPU request of at most 100m, a memory request of at most 256Mi and a memory limit of at most 256Mi
6. THE Monitoring_Manifests SHALL define a ServiceAccount, ClusterRole and ClusterRoleBinding for Kube_State_Metrics; the ClusterRole contains only the `get`, `list` and `watch` verbs and contains none of the `create`, `update`, `patch`, `delete` and `deletecollection` verbs
7. THE Monitoring_Manifests SHALL define a ServiceAccount and a ClusterRole containing only the `get`, `list` and `watch` verbs, together with a ClusterRoleBinding, so that Prometheus can perform scrape target discovery through the Kubernetes API
8. THE Monitoring_Manifests SHALL expose the Node_Exporter and Kube_State_Metrics ports so that the Monitoring_Instance can reach them, and restrict this access in the Demo_Cluster security group to the Monitoring_Security_Group source; they define no Service or Ingress object that is open to the public internet
9. THE Kube_State_Metrics SHALL emit the node schedulability status (`SchedulingDisabled`) as a metric, so that the node isolation signal is visible through Grafana_Cloud_Metrics
10. WHEN the Demo_Operator applies the Monitoring_Manifests, THE Monitoring_Manifests SHALL bring all of 1 Kube_State_Metrics pod and 2 Node_Exporter pods to the `Ready` state within 180 seconds

### Requirement 4: Metric Filtering and Series Budget

**User Story:** As a Demo_Operator, I want the metrics sent to stay within the free tier limit, so that the series limit is not reached and the data flow is not cut off in the middle of the demo.

#### Acceptance Criteria

1. THE Prometheus SHALL define a Metric_Allowlist in its configuration and send only the metric families named in this list to the Remote_Write_Endpoint
2. THE Metric_Allowlist SHALL include at least the following metric families: node CPU usage, node memory usage and total memory, container restart count, pod status, node schedulability status, and the scrape target reachability (`up`) metric
3. THE Series_Budget SHALL be defined as at most 6,000 active series and leave a margin of at least 4,000 series below the 10,000-series limit in the Free_Tier_Limits
4. THE Metric_Allowlist SHALL exclude high-cardinality container-level metric families that are not used by the Grafana_Dashboard panels
5. WHEN Prometheus runs without interruption for 15 minutes, THE Grafana_Cloud_Metrics SHALL report the number of active series below the Series_Budget value
6. THE Demo_Guide SHALL state the step in which the number of active series is checked in the Grafana_Cloud interface, and the Series_Budget value
7. IF the number of active series exceeds the Series_Budget value, THEN THE Demo_Guide SHALL provide a troubleshooting step that includes narrowing the Metric_Allowlist and names the metric families to be removed
8. THE Monitoring_Manifests SHALL provide the Metric_Allowlist definition in a single configuration file, editable from a single place

### Requirement 5: Monitoring Resilience and Behavior During a Disaster

**User Story:** As a Demo_Operator, I want the telemetry flow to continue without interruption during disaster scenarios and the fact that targets went down to be recorded, so that I can investigate the incident completely afterwards.

#### Acceptance Criteria

1. WHEN `disaster.sh` cordons the Isolate_Node, THE Prometheus SHALL keep running without interruption on the Monitoring_Instance and continue scraping both Worker_Node targets, because the Monitoring_Instance is not a node of the Demo_Cluster
2. WHILE `disaster.sh` is saturating the Stress_Node CPU, THE Prometheus SHALL continue scraping both Node_Exporter targets, writing to the Local_TSDB and sending to the Remote_Write_Endpoint, such that no gap longer than 60 seconds occurs between two consecutive successful writes
3. WHILE `disaster-oom.sh` is consuming the Stress_Node memory, THE Prometheus SHALL keep running without interruption and continue scraping the restart metrics coming from Kube_State_Metrics
4. IF the Node_Exporter pod on the Stress_Node is terminated due to memory exhaustion, THEN THE Prometheus SHALL, within at most 60 seconds, record the `up` value of only that target as 0, continue recording the Isolate_Node target with an `up` value of 1, and forward both values to the Remote_Write_Endpoint
5. WHEN the Node_Exporter pod on the Stress_Node becomes `Ready` again, THE Prometheus SHALL record the `up` value of that target as 1 again within at most 120 seconds
6. IF both Worker_Nodes become unavailable, THEN THE Prometheus SHALL keep running, record all targets with an `up` value of 0, and forward this record to the Remote_Write_Endpoint
7. THE Prometheus SHALL keep data in two separate copies during disaster scenarios, the Local_TSDB and Grafana_Cloud_Metrics; when one is unreachable, the other continues to serve the incident data
8. THE Demo_Guide SHALL state that the Monitoring_Instance is outside the Demo_Cluster and the Local_Zone and is therefore not affected by the injected disaster scenarios
9. THE Demo_Guide SHALL state that the Monitoring_Instance is in the same VPC, that a VPC-level outage could affect both the cluster and the Monitoring_Instance, and that in this case the copy in Grafana_Cloud_Metrics is preserved
10. THE Demo_Guide SHALL state that the target-down record (`up` value 0) is produced thanks to out-of-cluster scraping and that this record is a distinguishing signal for the investigation
11. WHEN `disaster.sh` is run, THE Grafana_Dashboard SHALL, at most 5 minutes after the script is started, show the Stress_Node series in the node CPU panel above 40 percent (observed behavior: CPU usage rises to about 50 percent within 2-3 minutes), and THE Grafana_Cloud_Metrics SHALL report `kube_node_spec_unschedulable` as 1 for the Isolate_Node
12. WHEN `disaster-oom.sh` is run, THE Grafana_Dashboard SHALL, at most 5 minutes after the script is started, show in the node memory panel the series of the affected node above 55 percent (observed behavior: about 61 percent) and the series of the idle node below 55 percent (observed behavior: about 39 percent), and show in the container restart panel an increase for the OOMKilled pods (observed behavior: 5 of 5 pods are OOMKilled and the cumulative restart count is 29 or more)
13. WHEN `disaster.sh` ends on its own after its 600-second duration or the corresponding cleanup script (`cleanup.sh`, `cleanup-oom.sh`) completes, THE Grafana_Dashboard SHALL, within at most 10 minutes, show the CPU and memory series of the affected node below the corresponding visual reference value (40 percent, 55 percent)
14. WHILE the memory load created by `disaster-oom.sh` persists and `cleanup-oom.sh` has not yet been run, THE Grafana_Dashboard SHALL keep showing the memory series of the affected node above 55 percent, because `disaster-oom.sh` does not end on its own

### Requirement 6: Grafana Dashboards

**User Story:** As a Demo_Operator, I want to see the three signals in separate panels and per node, so that I can tell at a glance which node is affected.

#### Acceptance Criteria

1. THE Grafana_Cloud_Stack SHALL provide the Grafana_Dashboard with at least 3 separate panels: (a) node CPU usage, (b) node memory usage, (c) container restart count; these three signals are not combined into a single panel
2. THE Grafana_Dashboard SHALL show a separate time series for each Worker_Node in the node CPU and node memory panels and label each series with the name of the corresponding node
3. THE Grafana_Dashboard SHALL show a separate series for each pod in the container restart panel and label each series with the pod name
4. THE Grafana_Dashboard SHALL show the unit as percent and the scale from 0 to 100 in the node CPU and node memory panels
5. WHEN Prometheus completes its first successful write request, THE Grafana_Dashboard SHALL show data in all three panels within at most 120 seconds
6. THE Demo_Guide SHALL state, for each disaster scenario, the Grafana_Dashboard panels to watch and the expected signals: for `disaster.sh`, a CPU spike of the Stress_Node series in the node CPU panel and `kube_node_spec_unschedulable=1` for the Isolate_Node; for `disaster-oom.sh`, memory growth of the affected node series in the node memory panel, an increase of the restart count in the container restart panel, and `up=0` for the Stress_Node node-exporter target during the OOM; the values 40 percent (CPU), 55 percent (memory) and 0 (restarts) are given only as visual reference values for the panels
7. IF a panel does not show data, THEN THE Demo_Guide SHALL provide a troubleshooting step that includes checking the status of the Prometheus service on the Monitoring_Instance, the scrape targets, the Remote_Write authentication and the scope of the Metric_Allowlist

### Requirement 7: Grafana Alert Rules — Out of scope (descoped)

**Status:** Descoped by operator decision. Grafana alert rules (CPU_Alert, Memory_Alert, Restart_Alert) are not implemented. Acceptance criterion numbers 7.1–7.13 are reserved for traceability and are not reused. Scenario signals are observed in the Grafana_Dashboard panels (Requirement 6), and investigations are started manually from the DevOps Agent console (Manual_Investigation).

### Requirement 8: Alert-Based Investigation Trigger — Out of scope (descoped)

**Status:** Descoped by operator decision. The webhook Contact_Point, the Notification_Policy, the `devops-agent-payload` Agent_Payload_Template and the automatic investigation trigger are not implemented. Acceptance criterion numbers 8.1–8.13 are reserved for traceability and are not reused. Investigations are started manually from the DevOps Agent console (Manual_Investigation).

### Requirement 9: DevOps Agent Grafana Integration

**User Story:** As a Demo_Operator, I want the Agent to be able to look at the Grafana metrics and dashboards, so that the investigation can be carried out even without CloudWatch data.

#### Acceptance Criteria

1. THE DevOps_Agent_Space SHALL be a single Agent Space in the `us-east-1` region whose Demo_Cluster and CloudWatch source points to `eu-central-1`; no separate Agent Space is created for Grafana; THE Demo_Guide SHALL direct the Demo_Operator to the AWS DevOps Agent documentation for the currently supported regions instead of asserting a region list
2. THE Capability_Provider SHALL be created as a single Grafana provider registration in the account-level providers section of the DevOps_Agent console; the service name of the registration contains only alphanumeric characters, hyphens and underscores
3. THE Capability_Provider SHALL use the Grafana_Cloud_Endpoint value as the Grafana URL and SHALL NOT use a private connection, because the Grafana_Cloud_Endpoint is a public HTTPS address and presents a valid public certificate
4. THE Capability_Provider SHALL use, for authentication, a Service_Account_Token starting with the `glsa_` prefix that belongs to a service account created with the `Viewer` role in the Grafana_Cloud_Stack
5. WHEN the Capability_Provider registration is created, THE Capability_Provider SHALL verify that the Grafana_Cloud_Endpoint address is reachable and responding; therefore the Grafana_Cloud_Stack is running before the registration attempt
6. WHEN the Capability_Provider registration completes successfully, THE Capability_Provider SHALL be attached to the existing DevOps_Agent_Space as a second telemetry source, next to the existing Demo_Cluster and CloudWatch source
7. THE DevOps_Agent SHALL execute only read tools on the Grafana_Cloud_Stack; write tools are disabled by the service and cannot be enabled, so the Agent cannot create, modify or delete dashboard, alert or annotation objects
8. WHEN an investigation is started through the DevOps_Agent_Space, THE DevOps_Agent SHALL include Grafana_Cloud_Metrics query results and Grafana_Dashboard content in the investigation context
9. THE Demo_Guide SHALL state that the proactive incident prevention flow does not use the Grafana tools and that ClickHouse data source tools are not supported
10. IF the Service_Account_Token expires or becomes invalid, THEN THE Capability_Provider SHALL report the authentication error and THE DevOps_Agent SHALL continue the investigation without Grafana data
11. WHERE the Service_Account_Token needs to be renewed, THE Demo_Guide SHALL state that the registration is renewed through the update operation, that the registration is not deleted, and that the existing DevOps_Agent_Space attachment is preserved
12. IF the Grafana_Cloud_Endpoint is unreachable during the Capability_Provider registration, THEN THE Capability_Provider SHALL NOT create the registration and THE Demo_Guide SHALL provide a troubleshooting step that includes checking that the Grafana_Cloud_Stack is running and that the address is spelled correctly

### Requirement 10: Source Attribution Comparison

**User Story:** As a demo viewer, I want to see which telemetry source each finding of one investigation came from, so that I understand the effect of the observability source on the investigation result.

#### Acceptance Criteria

1. THE Demo_Cluster SHALL, after the in-cluster monitoring components are installed, keep the `amazon-cloudwatch-observability` add-on in the `ACTIVE` state and keep the following three CloudWatch alarms defined: `eks-istanbul-high-cpu` (threshold 40 percent, statistic `Average`), `eks-istanbul-high-memory` (threshold 55 percent, statistic `Maximum`), `eks-istanbul-container-restarts` (threshold 0, statistic `Maximum`); the name, threshold and statistic of these three alarms remain exactly the same as their values before installation
2. THE DevOps_Agent_Space SHALL have exactly two telemetry sources attached: the Demo_Cluster and CloudWatch in `eu-central-1`, and the Grafana_Cloud_Stack through the Capability_Provider; no `kubectl` access is configured for the Agent
3. THE Demo_Guide SHALL state that the DevOps_Agent_Space is in `us-east-1` while the Demo_Cluster and all monitored resources are in `eu-central-1`
4. WHEN `disaster.sh` or `disaster-oom.sh` is run, THE Demo_Guide SHALL provide exactly one Manual_Investigation start step per scenario in the DevOps_Agent_Space
5. THE Demo_Guide SHALL use a single investigation prompt that is identical character for character for every scenario run; this prompt does not contain the name of the telemetry source, the node name, the metric name, the threshold value, the name of the scenario script that was run, or the expression `SchedulingDisabled`, so that the source attribution is not biased by the prompt
6. THE Comparison_Table SHALL contain, for each signal row, exactly two source columns (Found via CloudWatch/EKS and Found via Grafana Cloud) and carry exactly one value from the Comparison_Values set in each cell
7. THE Comparison_Table SHALL contain at least the following seven signals as separate rows: (a) node CPU usage, (b) node memory usage, (c) container restart count, (d) node isolation (`SchedulingDisabled`), (e) ENI churn activity, (f) CloudWatch alarm threshold history, (g) the cluster node count staying at 2
8. WHEN a cell value is `detected`, THE Comparison_Table SHALL include in that cell, as evidence, the corresponding metric or alarm name and the measured value within at most 200 characters
9. THE Demo_Guide SHALL state that the CloudWatch memory alarm is aggregated cluster-wide through the `ClusterName` dimension, so that in the OOM scenario, while the affected node is at about 61 percent and the idle node at about 39 percent, the cluster average stays at about 50 percent and is diluted below the 55 percent threshold, that this is why the alarm had to use the `Maximum` statistic, and that the Grafana_Dashboard panels show the same signal per node
10. WHEN the investigation is complete, THE Comparison_Table SHALL record in the node isolation row the Found via CloudWatch/EKS value according to the observed result (the CloudWatch-only baseline recorded `not detected`, because `SchedulingDisabled` is Kubernetes object state rather than a CloudWatch metric), and record the Found via Grafana Cloud value according to the observed result (whether `kube_node_spec_unschedulable` is used is an open question), thereby answering in writing the question of whether the schedulability metric coming from Kube_State_Metrics closes this gap
11. IF the investigation ends with an error or produces no finding within 30 minutes after it was started, or one source cannot be queried, THEN THE Comparison_Table SHALL fill the affected cells with the value `could not be investigated`, SHALL NOT leave the cells empty, and SHALL keep the findings of the other source unchanged
12. THE Demo_Guide SHALL state that the demo narrative changes from "we connected our self-hosted observability without exposing it to the internet" to "we connected third-party SaaS observability to the Agent"

### Requirement 11: Security and Secret Management

**User Story:** As a Demo_Operator, I want credentials not to enter the repository and no new public ingress rule to be added to the cluster, so that the demo environment stays secure.

#### Acceptance Criteria

1. THE Monitoring_Manifests SHALL read the Remote_Write_Credentials values as environment variables through references to Monitoring_Secret keys and SHALL NOT write these values as literal values in any manifest file
2. THE Monitoring_Manifests SHALL NOT contain, in any file under version control, the Remote_Write_Credentials value, the Service_Account_Token value, or the base64-encoded equivalent of these values
3. THE Monitoring_Setup_Script SHALL read the Remote_Write_Credentials values only from environment variables and SHALL NOT contain these values as hard-coded values in the script
4. IF at least one of the environment variables providing the Remote_Write_Credentials values is undefined or an empty string, THEN THE Monitoring_Setup_Script SHALL report the names of all missing or empty variables without printing their values, create no Kubernetes object, and exit with a non-zero exit code within at most 10 seconds
5. THE Monitoring_Setup_Script SHALL, in all messages it writes to standard output and standard error, write in place of secret values a fixed mask string that contains no character of the real value and consists of at most 8 masking characters
6. THE Monitoring_Manifests SHALL provide, for the Monitoring_Secret, a template file consisting only of placeholder fields, and keep the file containing the real values out of the repository through version control ignore rules
7. THE Demo_Cluster security group SHALL receive, for the Monitoring_Instance to scrape the exporters, only rules that reference the Monitoring_Security_Group as their source; it receives no new ingress rule open to the public internet, and no inbound access from Grafana_Cloud_Endpoint is required, because `remote_write` is an outbound connection
8. THE Demo_Cluster security group SHALL, after installation, contain only the TCP 80 and TCP 30000-32767 rules from a single operator IP address (`/32` source) and the exporter rules sourced from the Monitoring_Security_Group; no ingress rule with a source of `0.0.0.0/0` or `::/0` exists
9. THE Grafana_Cloud_Stack SHALL disable anonymous access; dashboard and metric content is not served to unauthenticated requests
10. THE Prometheus SHALL send to the Grafana_Cloud_Endpoint only metrics consisting of node names, pod names and resource usage values; it sends no log records, environment variable values or credentials
11. THE Demo_Guide SHALL state that the metrics leave the AWS account, that the data sent consists only of node and resource usage information, and that in an enterprise environment this decision must be evaluated separately

### Requirement 12: Phased Setup and Validation

**User Story:** As a Demo_Operator, I want to validate the setup phase by phase, so that when a phase fails I know which layer the problem is in.

#### Acceptance Criteria

1. WHEN the Monitoring_Setup_Script is run for the first phase, THE Monitoring_Setup_Script SHALL create only the Monitoring_Namespace, Node_Exporter and Kube_State_Metrics objects and SHALL NOT create any AWS DevOps_Agent resource, including the Capability_Provider and the DevOps_Agent_Space
2. WHEN the Monitoring_Setup_Script starts, THE Monitoring_Setup_Script SHALL check, before any manifest is applied and within at most 10 seconds, that the `kubectl` command is executable and that the current context shows the Demo_Cluster_Context value
3. IF the current `kubectl` context differs from the Demo_Cluster_Context value, THEN THE Monitoring_Setup_Script SHALL print the current context name and the expected value, offer the command `aws eks update-kubeconfig --region eu-central-1 --name eks-istanbul` as a remediation step, apply no manifest, and exit with a non-zero exit code
4. WHEN the Monitoring_Setup_Script applies the objects, THE Monitoring_Setup_Script SHALL wait up to 300 seconds, with a polling interval of at most 15 seconds, for all 3 expected pods (1 Kube_State_Metrics, 2 Node_Exporter) to reach the `Ready` state, and print on each poll the number of ready pods together with the expected number
5. IF at least one of the 3 expected pods does not reach the `Ready` state within 300 seconds, THEN THE Monitoring_Setup_Script SHALL report the name, current status and not-ready reason of every pod that is not ready, leave the created objects in place without deleting them, and exit with a non-zero exit code
6. THE Demo_Guide SHALL present the first phase validation as at least 2 numbered steps: (a) checking in the Grafana_Cloud interface that data is visible in all three panels of the Grafana_Dashboard, (b) checking that the number of active series is below the Series_Budget value
7. THE Demo_Guide SHALL present the second phase under a heading separate from the first phase, in the order (a) create the Service_Account_Token, (b) register the Capability_Provider, (c) attach the Capability_Provider to the existing DevOps_Agent_Space, (d) start a Manual_Investigation from the DevOps_Agent_Space, and SHALL state the condition that the second phase is not started before the first phase validation passes
8. THE Demo_Guide SHALL provide, as the second phase validation, a step that starts a Manual_Investigation through the DevOps_Agent_Space; as the pass criterion, it states that at least one metric finding coming from Grafana_Cloud_Metrics is visible in the investigation record
9. WHEN the Monitoring_Setup_Script is run a second time on the same Demo_Cluster after completing successfully, THE in-cluster monitoring components SHALL remain running with the same 3 pods, the pod restart counters do not change, no duplicate object is created, and the script exits with a zero exit code
10. WHEN the Monitoring_Setup_Script ends, THE Monitoring_Setup_Script SHALL write on its last output line the name of the executed phase and its result as succeeded or failed; if the result is failed, the same line includes the name of the failed step

### Requirement 13: Installation Method and Prerequisites

**User Story:** As a Demo_Operator, I want it to be stated clearly which tools are needed, so that the installation does not stop halfway because a tool is missing on my machine.

#### Acceptance Criteria

1. THE Monitoring_Manifests SHALL provide all in-cluster components as plain Kubernetes manifest files that can be applied with `kubectl apply` only; the manifest set contains no Helm chart, template variable or values file, and the installation can be completed end to end on a machine where the `helm` command is not installed
2. THE Monitoring_Setup_Script SHALL invoke only the `kubectl` command and contain no dependency on any other external command-line tool
3. IF the `kubectl` command is not executable on the local machine, THEN THE Monitoring_Setup_Script SHALL issue an error message that includes the name of the missing tool and a pointer to the README prerequisites table, apply no manifest, and exit with a non-zero exit code
4. THE Demo_Guide SHALL state that the Capability_Provider registration and the DevOps_Agent_Space attachment steps are carried out through the AWS Console and that the `devops-agent` subcommand is not recognized by the local AWS command-line tool
5. THE Demo_Guide SHALL state that the steps for creating the Grafana_Cloud_Stack, generating the Service_Account_Token and importing the Grafana_Dashboard are carried out through the Grafana_Cloud interface
6. THE README SHALL, in the prerequisites table, keep the existing `AWS CLI >= 2.x`, `Terraform >= 1.0` and `kubectl` rows, list the requirement value for Helm as "not required", and add a Grafana_Cloud account as a prerequisite

### Requirement 14: Lifecycle, Cleanup and Cost

**User Story:** As a Demo_Operator, I want monitoring to come back on its own after I scale the nodes to zero and back up, so that I do not have to reinstall between demos.

#### Acceptance Criteria

1. THE Monitoring_Manifests SHALL define the Kube_State_Metrics component as a Deployment and Node_Exporter as a DaemonSet, and use only the `role` node label as a placement constraint; no manifest file contains a node name, node private IP address, EC2 instance ID or Auto Scaling group name
2. WHEN the last Worker_Node leaves the cluster, THE in-cluster monitoring pods SHALL transition to the `Pending` state within at most 300 seconds with an event stating that no schedulable node exists, and the Grafana_Cloud_Metrics SHALL keep the metrics sent up to that point queryable for the Retention_Period
3. WHEN the number of Worker_Nodes is increased again to 1 Stress_Node and 1 Isolate_Node, THE in-cluster monitoring components SHALL bring all 3 pods to the `Ready` state within 300 seconds after the nodes become `Ready`, and SHALL NOT require any manual `kubectl apply` step from the Demo_Operator
4. WHEN the Worker_Nodes are recreated with new node names and new private IP addresses, THE Prometheus SHALL, within at most 120 seconds, drop the target entries that no longer exist and start sending the targets of the new nodes with an `up` value of 1
5. IF the node group is in the `DEGRADED` state because its Auto Scaling group was deleted, and an in-place scaling request is rejected due to an error stating that the Auto Scaling group cannot be found, THEN THE Demo_Guide SHALL provide a remediation path stating that the node group must be recreated by replacement and that no additional setup step is needed for monitoring after the recreation
6. THE Monitoring_Cleanup_Script SHALL remove all Deployment, DaemonSet, Service, ConfigMap, Secret and ServiceAccount objects in the Monitoring_Namespace, then the Monitoring_Namespace and the created ClusterRole and ClusterRoleBinding objects, and finish within at most 300 seconds
7. THE Monitoring_Cleanup_Script SHALL leave the `amazon-cloudwatch-observability` add-on and the three CloudWatch alarms preserved under Requirement 10 unchanged
8. THE Monitoring_Cleanup_Script SHALL NOT perform any delete or modify operation on the Grafana_Cloud_Stack, the Capability_Provider and the DevOps_Agent_Space
9. IF the Monitoring_Namespace or one of the objects to be removed does not already exist, THEN THE Monitoring_Cleanup_Script SHALL print the name of the missing object and that it was skipped, continue with the remaining cleanup steps, and exit with a zero exit code
10. THE Demo_Guide SHALL present the removal of the Grafana integration as a cleanup path separate from the Monitoring_Cleanup_Script, with the order being first detaching the Capability_Provider from the DevOps_Agent_Space, then the Capability_Provider, and last the Grafana_Cloud_Stack
11. THE README SHALL list the Grafana_Cloud free tier as 0 US dollars in the cost table and contain a separate row for the Monitoring_Instance and its attached disk; this row states that the charge is hourly and continues to accrue even when the worker nodes are scaled to zero
12. THE Demo_Guide SHALL provide a step to stop the Monitoring_Instance in order to stop cost outside the demo and state that the Prometheus service comes up on its own when the instance is restarted
13. WHEN the Monitoring_Instance is stopped and restarted, THE Prometheus SHALL start on its own as a service and resume scraping and forwarding to the Remote_Write_Endpoint within 120 seconds

### Requirement 15: Documentation Updates

**User Story:** As a Demo_Operator, I want the README and the demo guide to reflect the new observability path, so that I can run the demo end to end by following the documentation.

#### Acceptance Criteria

1. THE Demo_Guide SHALL direct the Demo_Operator to the AWS DevOps Agent documentation for the currently supported regions without asserting a region list, state that the single DevOps_Agent_Space used in this demo is in `us-east-1` while the monitored resources are in `eu-central-1`, and SHALL NOT contain, on any line, the outdated statement that DevOps_Agent is available only in the `us-east-1` region
2. THE README SHALL state that the single DevOps_Agent_Space used in this demo is in `us-east-1` and that the monitored resources are in `eu-central-1`, direct the operator to the AWS DevOps Agent documentation for the currently supported regions, and SHALL NOT contain the outdated statement presenting `us-east-1` as the only possible region
3. THE README SHALL, while preserving the existing ASCII diagram in the architecture section, add at least the following four items to the diagram: (a) Kube_State_Metrics running on the Isolate_Node in the Monitoring_Namespace and Node_Exporter running on each Worker_Node, (b) the Monitoring_Instance running in the Monitoring_Subnet outside the Local_Zone and the Demo_Cluster, with the Prometheus and Local_TSDB on it, (c) the scrape path from Prometheus to the Worker_Node exporters, the `remote_write` path from Prometheus to Grafana_Cloud, and a boundary showing that Grafana_Cloud is outside the AWS account, (d) one DevOps_Agent_Space node with two read paths, to the Demo_Cluster and CloudWatch in `eu-central-1` and to Grafana_Cloud over public HTTPS, with investigations started manually (Manual_Investigation)
4. THE README SHALL, while preserving unchanged the existing CloudWatch alarm table and the two subheadings that follow it, present immediately after them a separate table for the Grafana_Dashboard panels; this table contains exactly three rows (node CPU, node memory, container restarts) with the columns panel name, metric, visual reference value (40 percent, 55 percent, 0) and related disaster scenario
5. THE README SHALL, while preserving the existing entries in the repository structure tree, list the `k8s/monitoring/` directory, the Monitoring_Setup_Script and the Monitoring_Cleanup_Script, and write a description of at most one line for each entry
6. THE README SHALL keep the existing findings table, relabeled as the CloudWatch-only baseline recorded before the Grafana source was attached, preserve its node isolation row and existing value, and point to the Comparison_Table in the Demo_Guide for the per-source results
7. THE Demo_Guide SHALL present the in-cluster monitoring setup as a numbered step within the existing numbered step sequence, after the step in which the `kubectl` context is set and before the disaster scenario step, and present its cleanup as a numbered sub-step under the existing cleanup step
8. THE Demo_Guide SHALL present, separately for Scenario A (`disaster.sh`) and Scenario B (`disaster-oom.sh`), the Grafana_Dashboard panels to watch and the expected signals (Scenario A: CPU spike of the Stress_Node and `kube_node_spec_unschedulable=1` for the Isolate_Node; Scenario B: memory growth of the affected node, restart count increase, and Stress_Node node-exporter `up=0` during the OOM), stating an upper bound of at most 5 minutes for the signal to appear and at most 10 minutes for the return below the visual reference values, followed by the Manual_Investigation step in the DevOps_Agent_Space
9. THE Demo_Guide SHALL include the Comparison_Table with empty entry fields ready to be filled in, with the seven signal rows and two source columns defined in Requirement 10
10. THE Demo_Guide SHALL state the Free_Tier_Limits values, the Series_Budget value and that the Metric_Allowlist is applied, within a single note block
11. THE Demo_Guide SHALL add at least one item to the troubleshooting section for the case where no data is visible in the Grafana_Cloud panels
12. THE README SHALL keep unchanged the existing items in the Istanbul Local Zone known limitations section and state that these limitations do not apply to monitoring, because the monitoring path no longer requires a load balancer or VPC Lattice
13. THE demo SHALL remain fully deployable end to end with `terraform apply` followed by the documented scripts (`setup-monitoring.sh`, `provision-monitoring-instance.sh`) and the documented manual Grafana Cloud / AWS Console steps; no step depends on an undocumented manual change
14. THE README and the Demo_Guide SHALL be written in English
15. THE README, the Demo_Guide and all spec documents SHALL use placeholders (for example `<GRAFANA_CLOUD_USER>`, `<REMOTE_WRITE_PASSWORD>`, `<glsa_TOKEN>`) instead of real secret values; no access policy token, service account token, password or `remote_write` username value appears in any version-controlled file
