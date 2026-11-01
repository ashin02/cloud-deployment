variable "region" {
  description = "AWS region with EKS and at least two standard availability zones."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Unique name prefix within the account and region."
  type        = string
  default     = "cloud-deployment"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.project))
    error_message = "Use 3-30 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "admin_cidr" {
  description = "Administrator's public IPv4 CIDR for the EKS API, normally a single /32. Required; no world-open access."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && can(regex("/(2[4-9]|3[0-2])$", var.admin_cidr))
    error_message = "Specify an IPv4 CIDR with a /24 through /32 prefix; prefer your public IP/32."
  }
}

variable "admin_principal_arn" {
  description = "Existing IAM user or role to grant cluster administration. Root and STS session ARNs are not accepted."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/[A-Za-z0-9_+=,.@/-]+$", var.admin_principal_arn))
    error_message = "Provide an IAM user or role ARN in the commercial AWS partition, not a root or STS session ARN."
  }
}

variable "kubernetes_version" {
  description = "EKS version in standard support; review the AWS support calendar before recreating."
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = "x86_64 instance type for the AL2023 managed node group."
  type        = string
  default     = "c7i-flex.large"
}

variable "node_count" {
  description = "Fixed managed node group size. One node is economical but not highly available."
  type        = number
  default     = 1
  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3 && floor(var.node_count) == var.node_count
    error_message = "Choose an integer from 1 through 3 for this temporary experiment."
  }
}
