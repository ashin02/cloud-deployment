output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "ecr_url" {
  description = "Private ECR image repository URL."
  value       = aws_ecr_repository.app.repository_url
}

output "vpc_id" {
  description = "Experiment VPC ID."
  value       = aws_vpc.main.id
}
