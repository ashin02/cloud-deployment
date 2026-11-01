resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE"
  # Temporary experiment: terraform destroy also removes stored images.
  force_delete = true

  encryption_configuration {
    encryption_type = "AES256"
  }
}
