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
  tags = { Name = "${var.cluster_name}-vpc", "auto-delete" = "no" }
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
  alarm_name          = "${var.cluster_name}-high-memory"
  alarm_description   = "Node memory utilization above ${var.memory_threshold}% - possible memory exhaustion or leak"
  namespace           = "ContainerInsights"
  metric_name = "node_memory_utilization"
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
