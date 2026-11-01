# Publishing targets the existing west-region repository without moving EKS
# or changing the primary AWS provider's region.
provider "aws" {
  alias  = "publishing"
  region = "us-west-2"
}

data "aws_ecr_repository" "publishing" {
  provider = aws.publishing
  name     = "cloud-deployment"

  lifecycle {
    postcondition {
      condition     = self.image_tag_mutability == "IMMUTABLE"
      error_message = "The existing us-west-2 cloud-deployment repository must use IMMUTABLE tags."
    }
  }
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub owner ID for ashin02 (REST API owner.id)."
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "Provide the numeric GitHub owner ID."
  }
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository ID for ashin02/cloud-deployment (REST API id)."
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "Provide the numeric GitHub repository ID."
  }
}

variable "github_immutable_subject" {
  description = "Use the immutable default subject (required for repos created/renamed/transferred after July 15, 2026). Set false only for a verified legacy subject."
  type        = bool
  default     = true
}

locals {
  github_subject = var.github_immutable_subject ? "repo:ashin02@${var.github_owner_id}/cloud-deployment@${var.github_repository_id}:ref:refs/heads/main" : "repo:ashin02/cloud-deployment:ref:refs/heads/main"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github_publish" {
  name = "${var.project}-github-ecr-publish"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_publish" {
  name = "publish-cloud-deployment"
  role = aws_iam_role.github_publish.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
        ]
        Resource = data.aws_ecr_repository.publishing.arn
      }
    ]
  })
}

output "github_publish_role_arn" {
  description = "Set GitHub repository Actions variable AWS_PUBLISH_ROLE_ARN to this value."
  value       = aws_iam_role.github_publish.arn
}

output "github_oidc_subject" {
  description = "Exact GitHub OIDC subject allowed to assume the publishing role."
  value       = local.github_subject
}

output "publishing_ecr_url" {
  description = "Existing us-west-2 repository used by publishing (independent of the EKS provider region)."
  value       = data.aws_ecr_repository.publishing.repository_url
}
