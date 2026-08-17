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
