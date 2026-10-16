terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# --- Networking ---

resource "aws_vpc" "eks" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.cluster_name}-vpc", "auto-delete" = "no" }
}

resource "aws_internet_gateway" "eks" {
  vpc_id = aws_vpc.eks.id
  tags   = { Name = "${var.cluster_name}-igw", "auto-delete" = "no" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks.id
  }
  tags = { Name = "${var.cluster_name}-public-rt", "auto-delete" = "no" }
}

# Control plane subnets (Frankfurt - 2 AZs required)
resource "aws_subnet" "cp_a" {
  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.cluster_name}-cp-euc1a", "auto-delete" = "no" }
}

resource "aws_subnet" "cp_c" {
  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.20.2.0/24"
  availability_zone       = "${var.region}c"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.cluster_name}-cp-euc1c", "auto-delete" = "no" }
}

# Worker subnet (Istanbul Local Zone)
resource "aws_subnet" "istanbul" {
  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.20.10.0/24"
  availability_zone       = "eu-central-1-ist-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.cluster_name}-workers-istanbul", "auto-delete" = "no" }
}

resource "aws_route_table_association" "cp_a" {
  subnet_id      = aws_subnet.cp_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "cp_c" {
  subnet_id      = aws_subnet.cp_c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "istanbul" {
  subnet_id      = aws_subnet.istanbul.id
  route_table_id = aws_route_table.public.id
}

# --- IAM Roles ---

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  tags = { "auto-delete" = "no" }
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"
  tags = { "auto-delete" = "no" }
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_cloudwatch" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# --- EKS Cluster (control plane in Frankfurt) ---

resource "aws_eks_cluster" "istanbul" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn
  tags     = { "auto-delete" = "no" }

  vpc_config {
    subnet_ids              = [aws_subnet.cp_a.id, aws_subnet.cp_c.id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# --- Node Groups (workers in Istanbul Local Zone) ---

resource "aws_eks_node_group" "stress" {
  cluster_name    = aws_eks_cluster.istanbul.name
  node_group_name = "ng-istanbul-stress"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.istanbul.id]
  instance_types  = [var.instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  disk_size       = 20
  tags            = { "auto-delete" = "no" }

  labels = {
    role = "stress"
  }

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

resource "aws_eks_node_group" "isolate" {
  cluster_name    = aws_eks_cluster.istanbul.name
  node_group_name = "ng-istanbul-isolate"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.istanbul.id]
  instance_types  = [var.instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  disk_size       = 20
  tags            = { "auto-delete" = "no" }

  labels = {
    role = "isolate"
  }

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# --- Add-ons ---

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.istanbul.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.istanbul.name
  addon_name   = "coredns"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.istanbul.name
  addon_name   = "kube-proxy"
}

# Container Insights addon (depends on node groups being ready)
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = aws_eks_cluster.istanbul.name
  addon_name   = "amazon-cloudwatch-observability"

  depends_on = [
    aws_eks_node_group.stress,
    aws_eks_node_group.isolate,
  ]
}

# --- CloudWatch Alarm ---

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.cluster_name}-high-cpu"
  namespace           = "ContainerInsights"
  metric_name         = "node_cpu_utilization"
  statistic           = "Average"
  period              = 60
  threshold           = 40
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  depends_on = [aws_eks_addon.cloudwatch_observability]
}

# Node memory exhaustion (disaster-oom.sh scenario).
# Threshold sits between the observed idle baseline (~35-40%) and the
# incident level (~86%), so it separates the two without flapping.
resource "aws_cloudwatch_metric_alarm" "high_memory" {
  alarm_name        = "${var.cluster_name}-high-memory"
  alarm_description = "Node memory utilization above ${var.memory_threshold}% - possible memory exhaustion or leak"
  namespace         = "ContainerInsights"
  metric_name       = "node_memory_utilization"
  # Maximum, not Average: the ClusterName dimension aggregates across every
  # node, so a single exhausted node is diluted by the healthy ones. With two
  # nodes the cluster Average peaks near 50% while the affected node is at
  # ~61%, which would never cross the threshold. Maximum tracks the worst node.
  statistic           = "Maximum"
  period              = 60
  threshold           = var.memory_threshold
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  depends_on = [aws_eks_addon.cloudwatch_observability]
}

# Container restart loop (OOMKilled -> CrashLoopBackOff).
# Catches the restart signature even when node memory stays below the alarm
# threshold, which happens when the kernel reclaims memory faster than the
# kubelet housekeeping loop samples it.
resource "aws_cloudwatch_metric_alarm" "container_restarts" {
  alarm_name          = "${var.cluster_name}-container-restarts"
  alarm_description   = "Containers restarting repeatedly - possible OOMKill or CrashLoopBackOff"
  namespace           = "ContainerInsights"
  metric_name         = "pod_number_of_container_restarts"
  statistic           = "Maximum"
  period              = 60
  threshold           = var.restart_threshold
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  depends_on = [aws_eks_addon.cloudwatch_observability]
}

# --- Security Group Rules ---

resource "aws_security_group_rule" "worker_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip]
  security_group_id = aws_eks_cluster.istanbul.vpc_config[0].cluster_security_group_id
  description       = "Allow HTTP from my IP"
}

resource "aws_security_group_rule" "worker_nodeport_ingress" {
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip]
  security_group_id = aws_eks_cluster.istanbul.vpc_config[0].cluster_security_group_id
  description       = "Allow NodePort range from my IP"
}

# --- Monitoring Instance Security Group ---

# Security group for the out-of-cluster monitoring instance (Prometheus).
#
# Posture, in one sentence: nothing reaches this host from the internet except
# SSH from the operator's own address, and everything it needs it reaches
# outbound.
#
# No inline ingress/egress blocks here on purpose - the rules live in
# aws_security_group_rule resources below, matching how the cluster security
# group rules are already expressed in this file. Mixing the two styles makes
# Terraform fight itself on every apply.
resource "aws_security_group" "monitoring" {
  name        = "${var.cluster_name}-monitoring-sg"
  description = "Prometheus host: SSH from operator IP only, HTTPS out to Grafana Cloud, scrape out to VPC"
  vpc_id      = aws_vpc.eks.id
  tags        = { Name = "${var.cluster_name}-monitoring-sg", "auto-delete" = "no" }
}

# The only ingress rule on this security group.
#
# var.my_ip is a single /32 operator address. There is deliberately no rule for
# the Prometheus web port (9090): Prometheus binds 127.0.0.1:9090 on the host
# and the operator reaches the UI through an SSH tunnel over this same rule
# (ssh -L 9090:127.0.0.1:9090). Opening 9090 here would put an unauthenticated
# metrics UI on the public internet, so it stays closed.
#
# No ingress rule on this group may use 0.0.0.0/0 or ::/0 as a source.
resource "aws_security_group_rule" "monitoring_ssh_in" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip]
  security_group_id = aws_security_group.monitoring.id
  description       = "Allow SSH from my IP only (also carries the Prometheus UI tunnel)"
}

# Outbound HTTPS is required, not an oversight.
#
# Prometheus remote_writes every scraped sample to the Grafana Cloud endpoint
# over HTTPS. Grafana Cloud is SaaS behind rotating addresses, so the
# destination cannot be pinned to a CIDR. This is the intended data path out of
# the account; it opens nothing inbound.
resource "aws_security_group_rule" "monitoring_https_out" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.monitoring.id
  description       = "Allow HTTPS out for Prometheus remote_write to Grafana Cloud"
}

# Outbound to the VPC only, on the two exporter ports.
#
# Prometheus scrapes node-exporter (hostPort 9100) and kube-state-metrics
# (NodePort 30808) on the worker nodes in the Istanbul Local Zone subnet, which
# is inside this VPC. Scoped to the VPC CIDR rather than 0.0.0.0/0 so a
# misconfigured scrape target cannot reach off-VPC.
resource "aws_security_group_rule" "monitoring_node_exporter_out" {
  type              = "egress"
  from_port         = 9100
  to_port           = 9100
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.eks.cidr_block]
  security_group_id = aws_security_group.monitoring.id
  description       = "Allow scraping node-exporter inside the VPC"
}

resource "aws_security_group_rule" "monitoring_ksm_out" {
  type              = "egress"
  from_port         = 30808
  to_port           = 30808
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.eks.cidr_block]
  security_group_id = aws_security_group.monitoring.id
  description       = "Allow scraping kube-state-metrics NodePort inside the VPC"
}

# DNS to the Amazon-provided resolver, which lives inside the VPC CIDR.
# Without this the HTTPS egress rule above is useless: the Grafana Cloud
# remote_write hostname would never resolve.
resource "aws_security_group_rule" "monitoring_dns_udp_out" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [aws_vpc.eks.cidr_block]
  security_group_id = aws_security_group.monitoring.id
  description       = "Allow DNS (UDP) to the VPC resolver"
}

resource "aws_security_group_rule" "monitoring_dns_tcp_out" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.eks.cidr_block]
  security_group_id = aws_security_group.monitoring.id
  description       = "Allow DNS (TCP fallback) to the VPC resolver"
}

# --- Cluster Security Group: Exporter Ingress from the Monitoring Instance ---
#
# These two rules are the only thing that makes the in-cluster exporters
# reachable from the out-of-cluster Prometheus. Without them the scrape fails
# and the whole observability path is dead; with them wider than this, the
# cluster leaks metrics.
#
# Why source_security_group_id and never a CIDR:
#   1. Identity, not address. The monitoring host's private IP changes on every
#      stop/start and its public IP changes more often than that. A CIDR rule
#      would silently stop matching; a security-group reference keeps working
#      because it names *which instance*, not *where it currently is*.
#   2. It is the paved-path shape for service-to-service ingress inside a VPC,
#      and it is self-documenting: the rule states that exactly one host - the
#      Prometheus instance - may scrape.
#
# Why that matters more than usual here: both ports serve unauthenticated
# plaintext HTTP. node-exporter and kube-state-metrics have no auth, no TLS,
# and no concept of a caller. Anyone who can open a TCP connection reads every
# node and pod metric in the cluster. Network reachability IS the entire access
# control for these endpoints - there is no second gate behind them. So the
# source is pinned to the monitoring security group and nothing else.
#
# Hard constraint: neither rule may use cidr_blocks, and 0.0.0.0/0 or ::/0 as a
# source is prohibited on both (Requirement 11.8).
#
# Relationship to the pre-existing NodePort rule: worker_nodeport_ingress above
# already covers 30000-32767 - which includes 30808 - but only from var.my_ip,
# the operator's own /32. That rule exists so the operator can reach demo
# NodePorts from their workstation and is deliberately left untouched. The rule
# below adds the monitoring security group as an *additional* permitted source
# for 30808 alone; it does not widen, replace, or re-scope the operator rule.
# Two rules on the same port with different sources is the correct shape - AWS
# evaluates security group rules as a union, so each source is granted
# independently and narrowly.

# node-exporter, published as a hostPort on every worker node (DaemonSet, both
# nodes including Stress_Node). Not covered by any existing rule, so without
# this rule the node CPU and memory panels never receive data.
resource "aws_security_group_rule" "cluster_node_exporter_in" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = aws_eks_cluster.istanbul.vpc_config[0].cluster_security_group_id
  description              = "Allow Prometheus (monitoring SG) to scrape node-exporter hostPort 9100"
}

# kube-state-metrics, published as a NodePort Service on 30808 (single replica
# on Isolate_Node). Source is the monitoring security group so the scrape keeps
# working independently of the monitoring instance's current IP.
resource "aws_security_group_rule" "cluster_ksm_in" {
  type                     = "ingress"
  from_port                = 30808
  to_port                  = 30808
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = aws_eks_cluster.istanbul.vpc_config[0].cluster_security_group_id
  description              = "Allow Prometheus (monitoring SG) to scrape kube-state-metrics NodePort 30808"
}

# --- Monitoring Instance: IAM Role ---

# The instance role exists for exactly one reason: EC2 based target discovery.
#
# Prometheus uses ec2_sd_configs to find the worker nodes, filtered on
# tag:eks:cluster-name = eks-istanbul. That call is ec2:DescribeInstances and
# nothing else. This is the decision recorded in the design under "Target
# Discovery - Decision and Rationale": discovering targets through the EC2 API means the host
# needs no Kubernetes credential at all - no ServiceAccount token copied onto
# the box, no aws-iam-authenticator binary, no EKS access entry to maintain -
# and node IP changes are picked up on their own.
resource "aws_iam_role" "monitoring" {
  name = "${var.cluster_name}-monitoring-role"
  tags = { "auto-delete" = "no" }
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Least privilege inline policy, deliberately not a managed policy.
#
# The obvious managed candidates (AmazonEC2ReadOnlyAccess and friends) grant
# dozens of Describe* actions across EC2, ELB and Auto Scaling. This host needs
# one action, so it gets one action: anything more would be privilege the
# Prometheus process could use but never needs.
#
# Resource = "*" is not carelessness. ec2:DescribeInstances does not support
# resource level permissions - the AWS service authorization reference lists no
# resource types for it, so an ARN in the Resource element would make the
# policy match nothing and discovery would fail. Scoping is instead done where
# it can be: in the Prometheus ec2_sd_configs filters, and by the action list
# being a single read-only Describe.
resource "aws_iam_role_policy" "monitoring_ec2_discovery" {
  name = "${var.cluster_name}-monitoring-ec2-discovery"
  role = aws_iam_role.monitoring.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:DescribeInstances"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.cluster_name}-monitoring-profile"
  role = aws_iam_role.monitoring.name
  tags = { "auto-delete" = "no" }
}

# --- Monitoring Instance ---

# Latest Amazon Linux 2023 AMI, resolved at plan time rather than pinned.
#
# ARCHITECTURE WARNING: this filter is x86_64. var.monitoring_instance_type
# permits c7g.large, which is Graviton (arm64); selecting it without changing
# this filter to "al2023-ami-*-arm64" produces an instance that will not boot.
# variables.tf carries the same warning on the variable itself. The three other
# permitted types (c7i.large, c7i.xlarge, c6i.large) are x86_64 and need no
# change here.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# The observer, living outside the thing it observes.
#
# This instance is NOT a cluster node. It sits in the Frankfurt control plane
# subnet (aws_subnet.cp_c - eu-central-1c, euc1-az1, 10.20.2.0/24), outside the
# Istanbul Local Zone where the workers run, so none of the injected disaster
# scenarios touch it. That is the whole point: it stays up while the cluster
# degrades, which is what lets it record a target going down (up = 0).
#
# The subnet is referenced through the resource, never by its literal ID, so
# the configuration survives a VPC rebuild.
resource "aws_instance" "monitoring" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.monitoring_instance_type
  subnet_id     = aws_subnet.cp_c.id

  # A newer AL2023 AMI must not replace a running, provisioned observer.
  lifecycle {
    ignore_changes = [ami]
  }

  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  # An empty ssh_key_name must not break apply, so it collapses to null (no
  # key pair) rather than being passed through as "". See the variable
  # description: no key pair means no SSH, which is only acceptable when the
  # host is provisioned by other means.
  key_name = var.ssh_key_name != "" ? var.ssh_key_name : null

  # A public IP is required for the outbound remote_write to Grafana Cloud. It
  # exposes nothing: the security group admits SSH from a single operator /32
  # and Prometheus binds 127.0.0.1 only. The alternative - private subnet plus
  # NAT gateway - was priced at roughly $32/month and declined in design.md.
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.monitoring_disk_size
    encrypted   = true
  }

  # SECURITY, BINDING: user_data carries NO secrets, ever.
  #
  # user_data is readable from the instance metadata service by anything
  # running on this host, including the Prometheus process itself and any
  # future workload on the box. A Grafana Cloud remote_write password written
  # here would be readable by all of them, and it would also land in the
  # Terraform state file and in `terraform show` output.
  #
  # So this script does only what is safe to be public: install the Prometheus
  # package, create /etc/prometheus and the TSDB data directory, and set
  # ownership. It writes no prometheus.yml and no credentials.
  #
  # The actual configuration and the remote_write password file arrive later
  # over SSH via scripts/provision-monitoring-instance.sh (task 4.3), which
  # writes /etc/prometheus/remote_write_password with mode 0600 and reads the
  # value from the operator's environment.
  user_data = <<-EOT
    #!/bin/bash
    set -uo pipefail

    # Not set -e: a repository miss on the Prometheus package must not abort
    # the directory preparation below. The provisioning script installs the
    # binary from the upstream release tarball if the package is unavailable,
    # so a failure here is recoverable and the directories still need to exist.
    dnf install -y tar gzip
    dnf install -y prometheus2 || dnf install -y prometheus || true

    # The service account is created here rather than assumed, because it only
    # exists if the package install above succeeded.
    getent group prometheus >/dev/null || groupadd --system prometheus
    getent passwd prometheus >/dev/null || \
      useradd --system --no-create-home --shell /sbin/nologin -g prometheus prometheus

    install -d -m 0755 -o prometheus -g prometheus /etc/prometheus
    install -d -m 0750 -o prometheus -g prometheus /var/lib/prometheus

    # Intentionally no service start here: without a configuration file
    # Prometheus has nothing to scrape. provision-monitoring-instance.sh
    # delivers the config and enables the systemd unit.
  EOT

  tags = {
    Name          = "${var.cluster_name}-monitoring"
    Role          = "monitoring"
    "auto-delete" = "no"

    # Spelled out so this host is never mistaken for a cluster node during an
    # incident, and so the EKS node tooling has no reason to touch it. It
    # deliberately carries no eks:cluster-name tag, which also keeps it out of
    # its own ec2_sd_configs discovery results.
    NotACluster = "true"
    Component   = "prometheus"
  }

  depends_on = [aws_iam_role_policy.monitoring_ec2_discovery]
}
