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
