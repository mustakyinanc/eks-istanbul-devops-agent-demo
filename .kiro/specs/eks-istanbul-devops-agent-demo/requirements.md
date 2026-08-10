# Requirements Document

## Introduction

This feature formalizes the `eks-istanbul-devops-agent-demo` project: a reproducible demonstration that provisions an Amazon EKS cluster with worker nodes in the Istanbul Local Zone (`eu-central-1-ist-1a`), injects two simultaneous failures into that cluster, and then measures how much of the resulting incident AWS DevOps Agent can diagnose without human hints.

The demo has three distinct concerns:

1. **Infrastructure provisioning** — Terraform configuration that creates the VPC, Local Zone worker subnet, EKS control plane, two labelled node groups, IAM roles, observability add-ons, and a CloudWatch alarm.
2. **Disaster orchestration** — shell scripts that set up observability, inject the incident, and restore the cluster.
3. **Demo documentation and evaluation** — a guide that walks an operator through the full run, records which findings DevOps Agent detects, and states the known detection gap.

The requirements below describe the target behaviour of all three concerns. They also capture defects and inconsistencies found in the current repository: the referenced `k8s/stress-pod.yaml` manifest does not exist, `disaster.sh` deploys ten stress pods while the documentation states six, the scripts hardcode cluster name and region values that the Terraform configuration already exposes as variables, and the demo guide numbers its sub-steps inconsistently with its step headings.

## Glossary

- **Demo_Operator**: The human engineer who runs the demo end to end from a local workstation.
- **Terraform_Stack**: The Terraform configuration under `terraform/` that provisions all AWS resources for the demo.
- **Demo_Cluster**: The Amazon EKS cluster created by the Terraform_Stack, named by the `cluster_name` variable (default `eks-istanbul`).
- **Control_Plane_Region**: The AWS parent region hosting the EKS control plane, named by the `region` variable (default `eu-central-1`).
- **Local_Zone**: The AWS Local Zone `eu-central-1-ist-1a` that hosts the demo worker nodes.
- **Stress_Node_Group**: The managed node group `ng-istanbul-stress`, whose nodes carry the Kubernetes label `role=stress`.
- **Isolate_Node_Group**: The managed node group `ng-istanbul-isolate`, whose nodes carry the Kubernetes label `role=isolate`.
- **Stress_Node**: A worker node carrying the label `role=stress`; the target of CPU load injection.
- **Isolate_Node**: A worker node carrying the label `role=isolate`; the target of scheduling isolation.
- **Observability_Stack**: The `amazon-cloudwatch-observability` EKS add-on together with the CloudWatch metric alarm that watches node CPU utilization.
- **High_CPU_Alarm**: The CloudWatch metric alarm named `{cluster_name}-high-cpu` on the `ContainerInsights` / `node_cpu_utilization` metric.
- **Setup_Script**: `scripts/setup-alarm.sh`, which installs the observability add-on and creates the High_CPU_Alarm.
- **Disaster_Script**: `scripts/disaster.sh`, which injects the two failures.
- **Cleanup_Script**: `scripts/cleanup.sh`, which restores the Demo_Cluster to a healthy state.
- **Stress_Manifest**: The Kubernetes manifest `k8s/stress-pod.yaml` that defines a single CPU stress pod targeted at the Stress_Node.
- **Stress_Pod**: A pod created from the Stress_Manifest that consumes CPU on the Stress_Node.
- **DevOps_Agent**: AWS DevOps Agent, available in `us-east-1`, which performs the automated incident investigation.
- **Agent_Space**: A DevOps_Agent workspace configured with the Demo_Cluster and CloudWatch as data sources.
- **Investigation_Prompt**: The single unhinted prompt supplied to DevOps_Agent to start the investigation.
- **Demo_Guide**: The document `docs/demo-guide.md` that instructs the Demo_Operator step by step.
- **Findings_Table**: The table in the Demo_Guide and `README.md` recording which incident signals DevOps_Agent detected.
- **Access_CIDR**: The IPv4 CIDR block supplied through the `my_ip` variable, permitted to reach worker nodes.

## Requirements

### Requirement 1: Provision the Local Zone network foundation

**User Story:** As a Demo_Operator, I want Terraform to create a VPC that spans both the parent region and the Istanbul Local Zone, so that the EKS control plane and the Local Zone workers can communicate over one routable network.

#### Acceptance Criteria

1. THE Terraform_Stack SHALL create exactly one VPC in the Control_Plane_Region with the single IPv4 CIDR block `10.20.0.0/16`, with DNS support enabled and with DNS hostnames enabled, and SHALL associate no additional CIDR block with that VPC.
2. THE Terraform_Stack SHALL create exactly two control plane subnets inside the VPC: one with CIDR block `10.20.1.0/24` in availability zone `{region}a` and one with CIDR block `10.20.2.0/24` in availability zone `{region}c`, where `{region}` is the `region` variable value and the two availability zones are distinct.
3. THE Terraform_Stack SHALL create exactly one worker subnet inside the VPC with CIDR block `10.20.10.0/24` in availability zone `eu-central-1-ist-1a`, non-overlapping with both control plane subnet CIDR blocks.
4. THE Terraform_Stack SHALL enable public IPv4 address assignment on launch for all three subnets, so that every instance launched into any of the two control plane subnets or the worker subnet receives a public IPv4 address without an additional association step.
5. THE Terraform_Stack SHALL create exactly one internet gateway attached to the VPC and exactly one route table in that VPC containing one `0.0.0.0/0` route whose target is that internet gateway.
6. THE Terraform_Stack SHALL create exactly three route table associations, associating each of the two control plane subnets and the worker subnet with the single route table that carries the `0.0.0.0/0` route, so that no subnet remains on the VPC default route table.
7. THE Terraform_Stack SHALL tag the VPC, the internet gateway, the route table, the two control plane subnets, and the worker subnet, being 6 resources in total, with a `Name` tag whose value begins with the `cluster_name` variable value, is unique across those 6 resources, and with the tag `auto-delete` set to the exact value `no`.
8. IF the `region` variable value is any value other than `eu-central-1`, THEN THE Terraform_Stack SHALL reject the plan with an error message naming the `region` variable and stating that availability zone `eu-central-1-ist-1a` is reachable only from the `eu-central-1` parent region, and SHALL create no network resource.
9. IF the AWS account running the apply has not opted in to the `eu-central-1-ist-1a` zone group, THEN THE Terraform_Stack SHALL fail the apply with an error identifying the worker subnet and the `eu-central-1-ist-1a` availability zone, and SHALL leave the worker subnet, the Stress_Node_Group, and the Isolate_Node_Group uncreated while retaining the resources already created in state.
10. WHEN `terraform apply` runs a second time against unchanged configuration and unchanged variable values, THE Terraform_Stack SHALL report 0 resources to add, 0 to change, and 0 to destroy for the VPC, the internet gateway, the route table, the three subnets, and the three route table associations.

### Requirement 2: Provision IAM roles for the cluster and worker nodes

**User Story:** As a Demo_Operator, I want Terraform to create the IAM roles that EKS and the worker nodes require, so that the cluster reaches a healthy state and nodes publish metrics to CloudWatch without manual policy attachment.

#### Acceptance Criteria

1. WHEN the Demo_Operator applies the Terraform_Stack, THE Terraform_Stack SHALL create exactly one IAM role named `{cluster_name}-cluster-role` whose trust policy contains exactly one statement with effect allow, action `sts:AssumeRole`, and the single service principal `eks.amazonaws.com`, and SHALL tag that role with `auto-delete = "no"`.
2. WHEN the Terraform_Stack creates the role `{cluster_name}-cluster-role`, THE Terraform_Stack SHALL attach exactly one managed policy, `AmazonEKSClusterPolicy`, to that role, so that the role reports exactly one attached managed policy on completion of the apply.
3. WHEN the Demo_Operator applies the Terraform_Stack, THE Terraform_Stack SHALL create exactly one IAM role named `{cluster_name}-node-role` whose trust policy contains exactly one statement with effect allow, action `sts:AssumeRole`, and the single service principal `ec2.amazonaws.com`, and SHALL tag that role with `auto-delete = "no"`.
4. WHEN the Terraform_Stack creates the role `{cluster_name}-node-role`, THE Terraform_Stack SHALL attach exactly these four managed policies to that role: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, and `CloudWatchAgentServerPolicy`, so that the role reports exactly four attached managed policies on completion of the apply.
5. WHEN the Terraform_Stack creates the Demo_Cluster, THE Terraform_Stack SHALL begin the create operation only after the `AmazonEKSClusterPolicy` attachment on `{cluster_name}-cluster-role` has returned success, and SHALL pass the ARN of `{cluster_name}-cluster-role` as the Demo_Cluster service role.
6. WHEN the Terraform_Stack creates the Stress_Node_Group or the Isolate_Node_Group, THE Terraform_Stack SHALL begin each create operation only after all three of the `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, and `AmazonEC2ContainerRegistryReadOnly` attachments on `{cluster_name}-node-role` have returned success, and SHALL pass the ARN of `{cluster_name}-node-role` as the node role for both node groups.
7. IF an IAM role named `{cluster_name}-cluster-role` or `{cluster_name}-node-role` already exists in the target AWS account, THEN THE Terraform_Stack SHALL stop the apply before creating the Demo_Cluster, report an error naming the conflicting role name, and leave the pre-existing role unmodified.
8. IF a role creation or managed policy attachment in this requirement returns an authorization failure or any other error, THEN THE Terraform_Stack SHALL stop the apply before creating the Demo_Cluster, the Stress_Node_Group, and the Isolate_Node_Group, report an error naming the failed role or policy, and retain all resources already created in the Terraform state for a subsequent apply.

### Requirement 3: Provision the EKS control plane

**User Story:** As a Demo_Operator, I want the EKS control plane provisioned in the parent region with a publicly reachable API endpoint, so that I can drive the cluster with kubectl from my workstation.

#### Acceptance Criteria

1. THE Terraform_Stack SHALL create one EKS cluster in the Control_Plane_Region named by the `cluster_name` variable, which defaults to `eks-istanbul`, using the Kubernetes version given by the `kubernetes_version` variable, which defaults to `1.33`.
2. THE Terraform_Stack SHALL attach the Demo_Cluster to exactly the two control plane subnets described in Requirement 1 and to no other subnet.
3. THE Terraform_Stack SHALL configure the Demo_Cluster API endpoint with public access enabled and private access disabled, so that a cluster description reports public access `true` and private access `false`.
4. WHEN the Demo_Cluster reports status `ACTIVE`, THE Terraform_Stack SHALL install the EKS add-ons `vpc-cni`, `coredns`, and `kube-proxy` on the Demo_Cluster and SHALL treat installation as complete only when all three add-ons report status `ACTIVE` within 900 seconds each.
5. THE Terraform_Stack SHALL output the Demo_Cluster API endpoint and the Demo_Cluster name as non-empty, unmasked string values.
6. THE Terraform_Stack SHALL output a single-line runnable `aws eks update-kubeconfig` command in which the `region` and `cluster_name` variable values are already substituted, leaving no placeholder for the Demo_Operator to edit.
7. IF the Demo_Cluster does not reach status `ACTIVE` within 1800 seconds of the create call, THEN THE Terraform_Stack SHALL stop the apply with an error naming the Demo_Cluster and the timeout, exit with a non-zero status, and create no add-ons and no node groups.
8. IF any of the add-ons `vpc-cni`, `coredns`, or `kube-proxy` does not reach status `ACTIVE` within 900 seconds, THEN THE Terraform_Stack SHALL stop the apply with an error naming the affected add-on, exit with a non-zero status, and retain the already-created Demo_Cluster without rollback.
9. IF the `kubernetes_version` variable value does not match the `MAJOR.MINOR` form, THEN THE Terraform_Stack SHALL reject the plan with a message naming the `kubernetes_version` variable and the expected `MAJOR.MINOR` format.

### Requirement 4: Provision two labelled worker node groups in the Local Zone

**User Story:** As a Demo_Operator, I want two separately labelled node groups running in the Istanbul Local Zone, so that I can target CPU load at one node and scheduling isolation at the other.

#### Acceptance Criteria

1. THE Terraform_Stack SHALL create a managed node group named `ng-istanbul-stress` whose Kubernetes label `role=stress` is part of the node group create request, so that every node the group launches already reports `role=stress` when it first reaches `Ready` and no post-create labelling step is required.
2. THE Terraform_Stack SHALL create a managed node group named `ng-istanbul-isolate` whose Kubernetes label `role=isolate` is part of the node group create request, so that every node the group launches already reports `role=isolate` when it first reaches `Ready` and no post-create labelling step is required.
3. THE Terraform_Stack SHALL place the Stress_Node_Group and the Isolate_Node_Group in exactly one subnet each, that subnet being the Local_Zone worker subnet with CIDR block `10.20.10.0/24` in availability zone `eu-central-1-ist-1a` described in Requirement 1, and SHALL assign neither control plane subnet to either node group.
4. THE Terraform_Stack SHALL configure both node groups with the instance type given by the `instance_type` variable, AMI type `AL2023_x86_64_STANDARD`, and a root volume size of exactly 20 GB.
5. THE Terraform_Stack SHALL configure both node groups with desired size 1, minimum size 0, and maximum size 2, so that a successful apply yields exactly 1 Stress_Node and exactly 1 Isolate_Node.
6. THE Terraform_Stack SHALL default the `instance_type` variable to `c7i.large`, which the Local_Zone supports, and IF the `instance_type` variable value is an empty string, THEN THE Terraform_Stack SHALL reject the plan with a message naming the `instance_type` variable.
7. THE Terraform_Stack SHALL output, for the Stress_Node_Group and for the Isolate_Node_Group, one runnable `aws eks update-nodegroup-config` command each containing the `region` variable value, the `cluster_name` variable value, the node group name, and scaling configuration desired size 0, minimum size 0, and maximum size 2.
8. WHEN a node group create operation is submitted, THE Terraform_Stack SHALL wait for that node group to report status `ACTIVE` with 1 instance registered against the Demo_Cluster for up to 1800 seconds before creating any resource that depends on that node group.
9. IF a node group does not report status `ACTIVE` within 1800 seconds, THEN THE Terraform_Stack SHALL fail the apply with an error identifying the node group name and SHALL retain the VPC, subnets, IAM roles, and Demo_Cluster already created, so that the Demo_Operator can retry without re-provisioning them.
10. IF the Local_Zone rejects the node group because the zone group is not enabled or the requested instance type has no capacity in `eu-central-1-ist-1a`, THEN THE Terraform_Stack SHALL fail the apply with an error naming the node group, the requested instance type, and the availability zone, and SHALL retain the already-created resources so that the Demo_Operator can retry after enabling the zone group or changing the `instance_type` variable.

### Requirement 5: Restrict worker node network access to a single operator CIDR

**User Story:** As a Demo_Operator, I want node access limited to my own IP address, so that the publicly addressed Local Zone nodes are not exposed to the whole internet during the demo.

#### Acceptance Criteria

1. THE Terraform_Stack SHALL declare the `my_ip` variable as a string variable with no default value, so that the Access_CIDR value is supplied on every plan and apply.
2. THE Terraform_Stack SHALL create exactly one ingress rule on the Demo_Cluster security group with protocol TCP, from port 80, to port 80, and source CIDR equal to the Access_CIDR value.
3. THE Terraform_Stack SHALL create exactly one ingress rule on the Demo_Cluster security group with protocol TCP, from port 30000, to port 32767, and source CIDR equal to the Access_CIDR value.
4. IF the `my_ip` variable value is not four dotted decimal octets in the range 0 through 255 followed by `/` and a prefix length in the range 0 through 32, THEN THE Terraform_Stack SHALL reject the plan with a non-zero exit status and a message naming the `my_ip` variable and the expected `A.B.C.D/NN` format, and SHALL create or modify no AWS resource.
5. THE Terraform_Stack SHALL expose demo workloads through Kubernetes Services of type NodePort whose assigned node port falls in the range 30000 through 32767, reachable at a worker node public IPv4 address, and SHALL declare no Service of type LoadBalancer, because the Local_Zone provides no Classic, Application, or Network Load Balancer support.
6. IF no value for the `my_ip` variable is supplied at plan or apply time, THEN THE Terraform_Stack SHALL stop with a non-zero exit status reporting that the `my_ip` variable value is required, and SHALL create or modify no AWS resource.
7. IF the `my_ip` variable value has a prefix length shorter than 32 or equals `0.0.0.0/0`, THEN THE Terraform_Stack SHALL reject the plan with a non-zero exit status and a message stating that the `my_ip` variable must name a single host address ending in `/32`, and SHALL create or modify no AWS resource.
8. THE Terraform_Stack SHALL create no ingress rule on the Demo_Cluster security group whose source CIDR differs from the Access_CIDR value, so that worker node ports 80 and 30000 through 32767 stay reachable from the Access_CIDR only.

### Requirement 6: Establish CloudWatch observability and the high CPU alarm

**User Story:** As a Demo_Operator, I want Container Insights metrics and a CPU alarm in place before the incident, so that DevOps_Agent has observability data to reason over.

#### Acceptance Criteria

1. THE Terraform_Stack SHALL install the `amazon-cloudwatch-observability` add-on on the Demo_Cluster after the Stress_Node_Group and the Isolate_Node_Group are created.
2. THE Terraform_Stack SHALL create a CloudWatch metric alarm named `{cluster_name}-high-cpu` on namespace `ContainerInsights`, metric `node_cpu_utilization`, statistic `Average`, period 60 seconds, threshold 40 percent, comparison operator `GreaterThanThreshold`, and 1 evaluation period.
3. THE Terraform_Stack SHALL set the High_CPU_Alarm dimension `ClusterName` to the `cluster_name` variable value and set missing data treatment to `notBreaching`.
4. THE Terraform_Stack SHALL create the High_CPU_Alarm after the `amazon-cloudwatch-observability` add-on is installed.
5. WHEN the Setup_Script runs, THE Setup_Script SHALL request installation of the `amazon-cloudwatch-observability` add-on on the cluster named by its configured cluster name, and then wait for every CloudWatch agent pod in the `amazon-cloudwatch` namespace to reach the `Ready` condition for up to 180 seconds.
6. IF the `amazon-cloudwatch-observability` add-on already exists when the Setup_Script requests installation, THEN THE Setup_Script SHALL report that the add-on already exists, make no further installation attempt, and continue to the pod readiness wait of criterion 5 without setting a non-zero exit status.
7. IF at least one CloudWatch agent pod in the `amazon-cloudwatch` namespace does not reach the `Ready` condition within 180 seconds, THEN THE Setup_Script SHALL report that Container Insights pods failed to become ready, leave the add-on installed, and exit with a non-zero status without creating or modifying the High_CPU_Alarm.
8. WHEN every CloudWatch agent pod in the `amazon-cloudwatch` namespace has reached the `Ready` condition, THE Setup_Script SHALL wait at least 120 seconds for `ContainerInsights` metrics to reach CloudWatch and SHALL then create the High_CPU_Alarm with the name, namespace, metric, dimension, statistic, period, threshold, comparison operator, and evaluation period given in criteria 2 and 3.
9. IF an alarm named `{cluster_name}-high-cpu` already exists when the Setup_Script creates the High_CPU_Alarm, THEN THE Setup_Script SHALL replace that alarm's configuration with the values given in criteria 2 and 3 and SHALL exit with status 0, so that a repeated Setup_Script run leaves exactly one alarm with those values.
10. WHEN the High_CPU_Alarm creation completes, THE Setup_Script SHALL report the High_CPU_Alarm name and the 40 percent threshold value and exit with status 0.

### Requirement 7: Inject the two-failure incident

**User Story:** As a Demo_Operator, I want a single command that isolates one node and saturates the other node's CPU, so that the incident is reproducible across demo runs.

#### Acceptance Criteria

1. WHEN the Disaster_Script starts, THE Disaster_Script SHALL count the worker nodes whose `Ready` condition is `True`, and SHALL treat every other node status as not ready.
2. WHILE at least 1 worker node is registered and fewer than 2 worker nodes are in `Ready` state, THE Disaster_Script SHALL re-check node readiness at 15 second intervals for up to 180 seconds before evaluating criterion 4.
3. IF no worker node is registered with the Demo_Cluster, THEN THE Disaster_Script SHALL print the current node list and exit with a non-zero status before making any change to the Demo_Cluster.
4. IF fewer than 2 worker nodes are in `Ready` state after the 180 second readiness wait, THEN THE Disaster_Script SHALL print the current node list and exit with a non-zero status before making any change to the Demo_Cluster.
5. WHEN at least 2 worker nodes are in `Ready` state, THE Disaster_Script SHALL cordon every node carrying the label `role=isolate` so that each Isolate_Node reports `SchedulingDisabled`.
6. WHEN every node carrying the label `role=isolate` reports `SchedulingDisabled`, THE Disaster_Script SHALL create each Stress_Pod from the Stress_Manifest with a node selector of `role=stress`, so that every Stress_Pod is scheduled onto a Stress_Node.
7. WHEN the Disaster_Script creates Stress_Pods, THE Disaster_Script SHALL create exactly 6 Stress_Pods, each with a distinct name, matching the Stress_Pod count stated in the Demo_Guide and `README.md`.
8. WHEN the Disaster_Script creates each Stress_Pod, THE Disaster_Script SHALL bound that Stress_Pod's CPU load duration to 600 seconds, so that load stops without operator action if the demo is abandoned.
9. IF a Stress_Pod with the requested name already exists, THEN THE Disaster_Script SHALL report the existing pod by name, skip creating it, continue with the remaining Stress_Pods of the 6, and exit with status 0 provided no other step fails.
10. WHEN all 6 Stress_Pod creation attempts complete, THE Disaster_Script SHALL re-check Stress_Pod status at 10 second intervals for up to 60 seconds until every Stress_Pod reports `Running` or `Completed`, and SHALL then print the node list with each node's scheduling status and the node placement of every Stress_Pod.
11. IF the Stress_Manifest is absent or unreadable at `k8s/stress-pod.yaml`, THEN THE Disaster_Script SHALL report the unreadable manifest path and exit with a non-zero status before cordoning any node.
12. IF no node carries the label `role=isolate`, or a cordon operation on such a node returns a non-zero status, THEN THE Disaster_Script SHALL report the failed isolation step, print the current node list, and exit with a non-zero status without creating any Stress_Pod.
13. IF fewer than 6 Stress_Pods report `Running` or `Completed` after the 60 second wait in criterion 10, THEN THE Disaster_Script SHALL print the name and current phase of each Stress_Pod that did not reach `Running` or `Completed` and exit with a non-zero status, leaving the created Stress_Pods and the cordon in place.

### Requirement 8: Provide the stress pod manifest

**User Story:** As a Demo_Operator, I want the CPU stress workload defined in a version-controlled manifest, so that the injected load is reviewable and identical on every run.

#### Acceptance Criteria

1. THE Stress_Manifest SHALL exist at `k8s/stress-pod.yaml` as a valid Kubernetes YAML document declaring exactly one object of kind `Pod` in the `default` namespace, because the Demo_Guide and `README.md` both reference that path and the Cleanup_Script deletes Stress_Pods by name in the `default` namespace.
2. THE Stress_Manifest SHALL declare a node selector of `role=stress` as its only scheduling constraint, so that every Stress_Pod created from it is placed on a Stress_Node and on no other node.
3. THE Stress_Manifest SHALL declare the `hande007/stress-ng` container image with arguments that load 2 CPU workers for a bounded duration of 600 seconds, matching the 600 second bound stated in Requirement 7.
4. THE Stress_Manifest SHALL declare a `restartPolicy` of `Never`, so that a Stress_Pod that reaches `Succeeded` at the end of the 600 second load period stays completed and is not restarted.
5. THE Disaster_Script SHALL create each of the 6 Stress_Pods required by Requirement 7 from the Stress_Manifest, overriding only the pod name so that each Stress_Pod carries a distinct name in the `default` namespace.
6. THE Disaster_Script SHALL contain no inline Stress_Pod specification, so that the Stress_Manifest is the single definition governing container image, load arguments, node selector, and restart policy.
7. IF the Stress_Manifest is absent from `k8s/stress-pod.yaml` or the Kubernetes API rejects it as invalid, THEN THE Disaster_Script SHALL report an error naming the `k8s/stress-pod.yaml` path and exit with a non-zero status without cordoning any Isolate_Node and without creating any Stress_Pod.
8. IF no node carrying the label `role=stress` is in `Ready` state when a Stress_Pod is created from the Stress_Manifest, THEN THE Stress_Pod SHALL remain unscheduled in `Pending` state rather than being placed on an Isolate_Node or any unlabelled node.

### Requirement 9: Restore the cluster after the demo

**User Story:** As a Demo_Operator, I want a single command that removes the injected load and lifts the isolation, so that I can re-run the demo without re-provisioning infrastructure.

#### Acceptance Criteria

1. WHEN the Cleanup_Script runs, THE Cleanup_Script SHALL request deletion of every Stress_Pod using the same pod names and namespace that the Disaster_Script uses, covering the full Stress_Pod count stated in the Demo_Guide and `README.md`, and SHALL wait up to 60 seconds for each deletion request to be acknowledged.
2. WHEN the Cleanup_Script runs, THE Cleanup_Script SHALL uncordon every node carrying the label `role=isolate` and SHALL confirm within 30 seconds that no node carrying that label reports `SchedulingDisabled`, so that each Isolate_Node returns to a schedulable state.
3. IF a Stress_Pod named by the Cleanup_Script is absent, already deleted, or already in a terminated state, THEN THE Cleanup_Script SHALL continue with the remaining cleanup steps and SHALL leave its exit status at 0, treating a never-created pod and an already-deleted pod identically.
4. WHEN every Stress_Pod deletion request has been issued and every uncordon action has completed, THE Cleanup_Script SHALL print, for each worker node, the node name, the `Ready` condition, and whether the node is schedulable, so that the Demo_Operator can confirm the restored state.
5. WHEN the Cleanup_Script runs after the Disaster_Script and then the Disaster_Script runs again, THE Demo_Cluster SHALL reach an incident state in which every node carrying the label `role=isolate` reports `SchedulingDisabled` and the Stress_Pod count stated in the Demo_Guide and `README.md` is in `Running` state on a Stress_Node within 60 seconds, matching the state produced by the first Disaster_Script run, so that the cleanup and injection cycle is repeatable.
6. IF no node carrying the label `role=isolate` is found when the Cleanup_Script runs, THEN THE Cleanup_Script SHALL print a message indicating that no Isolate_Node was found, continue with the remaining cleanup steps, and leave its exit status at 0.
7. IF any Stress_Pod named by the Cleanup_Script is still present in a non-terminated state 60 seconds after its deletion was requested, THEN THE Cleanup_Script SHALL print the pods that remain, report an error indicating that pod cleanup did not complete, and exit with a non-zero status while leaving the completed uncordon result in place.
8. WHEN every Stress_Pod deletion request has been acknowledged and every node carrying the label `role=isolate` reports a schedulable state, THE Cleanup_Script SHALL exit with status 0.

### Requirement 10: Derive script configuration from the Terraform stack

**User Story:** As a Demo_Operator, I want the scripts to use the same cluster name and region as Terraform, so that a renamed cluster or a different region does not silently break the demo.

#### Acceptance Criteria

1. THE Setup_Script SHALL accept the cluster name and the Control_Plane_Region as inputs supplied through a command-line option or an environment variable, and SHALL apply the Terraform_Stack variable defaults `eks-istanbul` for the cluster name and `eu-central-1` for the Control_Plane_Region when neither input is supplied.
2. THE Setup_Script SHALL derive the High_CPU_Alarm name as the configured cluster name followed by the suffix `-high-cpu`, so that the alarm name matches the alarm created by the Terraform_Stack.
3. WHERE the Demo_Operator supplies a cluster name or a Control_Plane_Region value, THE Setup_Script SHALL use the supplied value in every AWS CLI invocation and every kubectl invocation it makes, and SHALL use no cluster name or region literal other than the configured values.
4. IF a required AWS CLI command, a required kubectl command, an input validation check, or a prerequisite check in the Setup_Script, the Disaster_Script, or the Cleanup_Script fails, THEN THE containing script SHALL stop its remaining work, report a message naming the step that failed, and exit with a non-zero status.
5. WHERE a script performs local cleanup after a failed command, THE script SHALL complete that cleanup, report a message naming the step that failed, and exit with a non-zero status rather than status 0.
6. THE Disaster_Script and the Cleanup_Script SHALL each accept the cluster name and the Control_Plane_Region as inputs supplied through a command-line option or an environment variable, SHALL apply the same defaults stated in criterion 1 when neither input is supplied, and SHALL use the configured values in every AWS CLI invocation, every kubectl invocation, and every alarm name they print.
7. IF a supplied cluster name is empty, exceeds 100 characters, or contains a character outside the set of letters, digits, and hyphen, or IF a supplied Control_Plane_Region value is empty or exceeds 30 characters, THEN THE containing script SHALL report a message naming the rejected input and its expected format and exit with a non-zero status before making any AWS CLI call or kubectl call.
8. IF the configured cluster is not found in the configured Control_Plane_Region, THEN THE containing script SHALL report a message naming the configured cluster name and the configured region and exit with a non-zero status before making any change to any cluster, alarm, node, or pod.

### Requirement 11: Document the end-to-end demo procedure

**User Story:** As a Demo_Operator following the guide for the first time, I want an ordered procedure with verification points, so that I can complete the demo without prior knowledge of the repository.

#### Acceptance Criteria

1. THE Demo_Guide SHALL state, for each of AWS CLI, Terraform, and kubectl, a minimum supported version as a complete three-part version number and the version-check command whose output the Demo_Operator compares against that minimum.
2. THE Demo_Guide SHALL instruct the Demo_Operator to enable the `eu-central-1-ist-1a` zone group in the EC2 console before running `terraform apply`, and SHALL state that the Demo_Operator proceeds only once the zone group status reads `Enabled`, because the Local_Zone is disabled by default.
3. THE Demo_Guide SHALL present the demo steps in this order: enable the Local_Zone, apply the Terraform_Stack, configure kubeconfig, run the Setup_Script, configure the Agent_Space, run the Disaster_Script, wait for the High_CPU_Alarm, run the investigation, review the Findings_Table, run the Cleanup_Script, scale node groups to zero, and destroy the Terraform_Stack.
4. THE Demo_Guide SHALL state, for each step that changes cluster or alarm state, one verification command or console check, the expected observable result of that check stated as a concrete value or status string, and the maximum number of minutes the Demo_Operator waits for that result before treating the step as failed.
5. THE Demo_Guide SHALL state the expected wall clock duration of the Terraform apply, the observability setup, the High_CPU_Alarm transition from `OK` to `ALARM`, and the DevOps_Agent investigation, each as a whole number of minutes or a bounded range of whole minutes.
6. THE Demo_Guide SHALL state the hourly cost of the EKS control plane, the hourly cost per worker instance in the Local_Zone, and the monthly EBS cost for a 20 GB root volume, each as a numeric amount with its currency and its billing unit, so that the Demo_Operator can estimate the cost of a demo run.
7. THE Demo_Guide SHALL state the Local_Zone constraints as four explicit statements: which load balancer types are unsupported, whether Spot instances are supported, the instance families that are supported, and the minimum supported instance size.
8. THE Demo_Guide SHALL provide, for each of `terraform apply` failing on the Local_Zone subnet, `kubectl` returning no nodes, Container Insights pods failing to start, the High_CPU_Alarm remaining in `OK` after injection, and DevOps_Agent failing to locate the Demo_Cluster, a troubleshooting entry containing the observed symptom, the cause, and the corrective command or console action, and SHALL identify any referenced step by the step number under which that action appears in the procedure.
9. THE Demo_Guide SHALL number its steps as a contiguous sequence starting at 1 with no repeated or skipped number, SHALL prefix every sub-step identifier with the number of the step that contains it, and SHALL reference every step by that same number in all cross-references and command captions.
10. THE Demo_Guide SHALL state, for every command block, the working directory from which the command runs, expressed as a path relative to the repository root.
11. THE Demo_Guide SHALL state the Stress_Pod count that the Disaster_Script creates, and that stated count SHALL equal the count created by the Disaster_Script and the count stated in `README.md`.

### Requirement 12: Configure the DevOps Agent investigation

**User Story:** As a Demo_Operator, I want documented steps for wiring DevOps_Agent to the cluster and CloudWatch, so that the agent investigates with the same data sources on every run.

#### Acceptance Criteria

1. THE Demo_Guide SHALL state that DevOps_Agent is reached in the `us-east-1` region and SHALL state that the Demo_Cluster and the High_CPU_Alarm reside in the Control_Plane_Region, so that the Demo_Operator expects a cross-region configuration.
2. THE Demo_Guide SHALL instruct the Demo_Operator to create an Agent_Space and register the Demo_Cluster as a cloud data source scoped to the Control_Plane_Region, and SHALL state the Demo_Cluster name and the Control_Plane_Region value to enter.
3. THE Demo_Guide SHALL instruct the Demo_Operator to register CloudWatch scoped to the Control_Plane_Region as an observability data source on the Agent_Space, and SHALL state that both data sources are registered on the same Agent_Space.
4. THE Demo_Guide SHALL instruct the Demo_Operator to confirm, before starting the investigation, that the cloud data source and the observability data source both report a connected status, and SHALL state that the status is re-checked at 30 second intervals for up to 5 minutes after saving each data source.
5. IF either data source still reports a status other than connected after the 5 minute re-check window, THEN THE Demo_Guide SHALL direct the Demo_Operator to correct the data source region and credentials and re-save the data source before starting the investigation, and SHALL state that the investigation is not started while any data source is not connected.
6. THE Demo_Guide SHALL state the Investigation_Prompt verbatim in a single copyable block, SHALL state that the Investigation_Prompt names the Demo_Cluster and the Control_Plane_Region, and SHALL state that the Investigation_Prompt contains no reference to node cordoning, the `SchedulingDisabled` condition, the Stress_Pods, CPU load, the High_CPU_Alarm, or the node group names, so that the prompt carries no diagnostic hint.
7. THE Demo_Guide SHALL instruct the Demo_Operator to submit the Investigation_Prompt exactly once and to submit no further prompt, correction, or follow-up question until the investigation reports completion, so that the recorded findings reflect unassisted agent behaviour.
8. THE Demo_Guide SHALL state the expected investigation duration as 5 to 15 minutes of wall clock time, and SHALL state that an investigation showing no new step for 30 minutes is treated as stalled and restarted from the same verbatim Investigation_Prompt with no added hints.
9. IF DevOps_Agent reports that the Demo_Cluster cannot be found, THEN THE Demo_Guide SHALL direct the Demo_Operator to verify that the Agent_Space cloud data source region equals the Control_Plane_Region and that the caller identity used by the Agent_Space is permitted to call `eks:DescribeCluster` across regions, and SHALL state that the investigation is restarted after the correction using the unchanged Investigation_Prompt.

### Requirement 13: Record investigation findings and the known detection gap

**User Story:** As a demo presenter, I want the expected agent findings and the known blind spot written down, so that the audience sees both the capability and the limit of automated investigation.

#### Acceptance Criteria

1. THE Findings_Table SHALL contain exactly 5 finding rows and a detection status column whose value for each row is one of exactly two states, detected or not detected, and SHALL list as detected the 4 findings high CPU utilization on the Stress_Node, elastic network interface churn attributable to VPC CNI activity, High_CPU_Alarm threshold history, and the absence of node scaling events during the incident window.
2. THE Findings_Table SHALL list Isolate_Node scheduling isolation as the single row with detection status not detected, and SHALL name Kubernetes API access as the missing prerequisite for that row.
3. THE Demo_Guide SHALL state that DevOps_Agent omits the `SchedulingDisabled` condition because it reads CloudWatch metrics and EC2 APIs while holding no Kubernetes API access.
4. THE Demo_Guide SHALL state the remediation for the omitted `SchedulingDisabled` condition as mapping the DevOps_Agent IAM role into the `aws-auth` ConfigMap in the `kube-system` namespace.
5. THE Findings_Table in `README.md` SHALL carry the same 5 finding rows in the same order with the same detection status per row as the Findings_Table in the Demo_Guide, so that the two documents report the same result.
6. THE Demo_Guide SHALL name the 5 EKS control plane log types `api`, `audit`, `authenticator`, `controllerManager`, and `scheduler` in one place and SHALL state that enabling them supplies control plane request and scheduling evidence that CloudWatch metrics alone do not provide.
7. WHEN the Demo_Operator reaches the findings review step, THE Demo_Guide SHALL provide a `kubectl` command whose output shows the Isolate_Node in `Ready,SchedulingDisabled` state, so that the undetected finding is confirmed independently of DevOps_Agent output.
8. IF the observed DevOps_Agent output for any Findings_Table row differs from the detection status recorded in that row, THEN THE Demo_Guide SHALL instruct the Demo_Operator to record the observed status alongside the expected status and to treat the recorded expectation as unverified for that run.

### Requirement 14: Tear down the demo predictably

**User Story:** As a Demo_Operator, I want a documented teardown path with an intermediate cost-saving state, so that I can pause the demo cheaply or remove it entirely.

#### Acceptance Criteria

1. THE Demo_Guide SHALL provide the two `aws eks update-nodegroup-config` commands that set the Stress_Node_Group and the Isolate_Node_Group to desired size 0, minimum size 0, and maximum size 2, SHALL state that worker instance and EBS charges stop once the nodes terminate, and SHALL state the hourly EKS control plane charge that continues while both node groups are scaled to zero.
2. THE Demo_Guide SHALL provide the `terraform destroy` command as the final teardown step, SHALL state that this step removes the VPC, Demo_Cluster, node groups, IAM roles, and High_CPU_Alarm, and SHALL state an expected wall clock duration of 10 to 20 minutes for that command.
3. WHERE the High_CPU_Alarm was created by the Setup_Script rather than by the Terraform_Stack, THE Demo_Guide SHALL provide the `aws cloudwatch delete-alarms` command naming the alarm `{cluster_name}-high-cpu` in the Control_Plane_Region and the `aws cloudwatch describe-alarms` check that returns an empty alarm list, so that no orphaned alarm remains after `terraform destroy`.
4. THE Terraform_Stack SHALL keep Terraform state files, Terraform state backup files, `.terraform` provider directories, `terraform.tfvars`, and Terraform apply and destroy log files excluded from version control, and SHALL keep `terraform.tfvars.example` included in version control, so that account-specific values and credentials stay out of the repository while the variable template remains available.
5. WHEN the Demo_Operator has run the scale-to-zero commands from criterion 1, THE Demo_Guide SHALL state the verification check confirming that the Demo_Cluster reports 0 registered worker nodes within 10 minutes of those commands.
6. WHERE the Demo_Operator resumes a paused demo, THE Demo_Guide SHALL provide the `aws eks update-nodegroup-config` commands that return the Stress_Node_Group and the Isolate_Node_Group to desired size 1, minimum size 0, and maximum size 2, and SHALL state that the Disaster_Script must be re-run after both nodes reach `Ready` state.
7. IF `terraform destroy` exits with a non-zero status, THEN THE Demo_Guide SHALL direct the Demo_Operator to check for remaining node groups, remaining elastic network interfaces in the Local_Zone worker subnet, and remaining security group references, and SHALL state that re-running `terraform destroy` after those dependencies are removed completes the teardown.
