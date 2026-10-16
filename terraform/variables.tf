variable "region" {
  description = "AWS region for the EKS control plane"
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-istanbul"
}

variable "kubernetes_version" {
  description = "Kubernetes version (EKS supports 1.31-1.36; 1.29 and older are end of standard support)"
  type        = string
  default     = "1.33"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "The kubernetes_version variable must use MAJOR.MINOR format, for example \"1.33\"."
  }
}

variable "instance_type" {
  description = "EC2 instance type for worker nodes (Istanbul LZ supports c7i, m7i, r7i)"
  type        = string
  default     = "c7i.large"
}

variable "my_ip" {
  description = "Your public IP address for NodePort and HTTP access (e.g. 1.2.3.4/32)"
  type        = string
}

variable "memory_threshold" {
  description = "Node memory utilization percent that triggers the high memory alarm, evaluated as the Maximum across nodes (idle baseline is ~39%, the memory exhaustion scenario drives the affected node to ~61%)"
  type        = number
  default     = 55

  validation {
    condition     = var.memory_threshold > 0 && var.memory_threshold <= 100
    error_message = "The memory_threshold variable must be greater than 0 and at most 100."
  }
}

variable "restart_threshold" {
  description = "Container restart count that triggers the restart loop alarm"
  type        = number
  default     = 0

  validation {
    condition     = var.restart_threshold >= 0
    error_message = "The restart_threshold variable must be 0 or greater."
  }
}
variable "monitoring_instance_type" {
  description = "EC2 instance type for the out-of-cluster monitoring instance that runs Prometheus. Must be compute optimized and offered in eu-central-1c (euc1-az1), the AZ of the monitoring subnet"
  type        = string
  default     = "c7i.large"

  validation {
    # Each type below was verified as offered in eu-central-1c. c7g is Graviton
    # (arm64): selecting it requires an arm64 AMI for aws_instance.monitoring,
    # otherwise the instance will not boot. The x86_64 types need no AMI change.
    condition     = contains(["c7i.large", "c7i.xlarge", "c6i.large", "c7g.large"], var.monitoring_instance_type)
    error_message = "The monitoring_instance_type variable must be one of c7i.large, c7i.xlarge, c6i.large, c7g.large. Note c7g.large is arm64 and requires a matching AMI."
  }
}

variable "monitoring_disk_size" {
  description = "Root gp3 volume size in GiB for the monitoring instance. 30 GiB is ample for a 24 hour local Prometheus TSDB; long term retention lives in Grafana Cloud"
  type        = number
  default     = 30

  validation {
    condition     = var.monitoring_disk_size >= 20 && var.monitoring_disk_size <= 200
    error_message = "The monitoring_disk_size variable must be between 20 and 200 GiB."
  }
}

variable "monitoring_local_retention" {
  description = "Local Prometheus TSDB retention passed to --storage.tsdb.retention.time. The local copy only guarantees continuity during a disaster scenario, so at least 24h is enough"
  type        = string
  default     = "24h"

  validation {
    condition     = can(regex("^[0-9]+(ms|s|m|h|d|w|y)$", var.monitoring_local_retention))
    error_message = "The monitoring_local_retention variable must be a Prometheus duration, for example \"24h\", \"90m\" or \"7d\"."
  }
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair used for SSH access to the monitoring instance. Account specific, so there is no sensible default; set it in terraform.tfvars (gitignored). An empty string attaches no key pair, which leaves the instance unreachable over SSH - acceptable only when the instance is provisioned by other means"
  type        = string
  default     = ""
}
