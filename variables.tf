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
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
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
