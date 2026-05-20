output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.istanbul.endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.istanbul.name
}

output "update_kubeconfig" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name}"
}

output "scale_to_zero" {
  description = "Commands to scale nodes to zero (cost saving)"
  value       = <<-EOT
    aws eks update-nodegroup-config --region ${var.region} --cluster-name ${var.cluster_name} --nodegroup-name ng-istanbul-stress --scaling-config minSize=0,maxSize=2,desiredSize=0
    aws eks update-nodegroup-config --region ${var.region} --cluster-name ${var.cluster_name} --nodegroup-name ng-istanbul-isolate --scaling-config minSize=0,maxSize=2,desiredSize=0
  EOT
}
