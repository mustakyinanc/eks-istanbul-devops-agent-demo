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

output "monitoring_private_ip" {
  description = "Private IP of the monitoring instance (the address the exporters see scraping them)"
  value       = aws_instance.monitoring.private_ip
}

output "monitoring_public_ip" {
  description = "Public IP of the monitoring instance (used for SSH and outbound remote_write; no inbound port is open except SSH from my_ip)"
  value       = aws_instance.monitoring.public_ip
}

output "monitoring_ssh" {
  description = "Command to SSH into the monitoring instance"
  value       = "ssh -i ~/.ssh/${var.ssh_key_name}.pem ec2-user@${aws_instance.monitoring.public_ip}"
}

output "monitoring_prometheus_tunnel" {
  description = "Commands to reach the Prometheus UI over an SSH tunnel (Prometheus binds 127.0.0.1:9090 only, so this is the only access path)"
  value       = <<-EOT
    ssh -i ~/.ssh/${var.ssh_key_name}.pem -L 9090:127.0.0.1:9090 ec2-user@${aws_instance.monitoring.public_ip}
    # then open http://127.0.0.1:9090/targets in a browser
  EOT
}
