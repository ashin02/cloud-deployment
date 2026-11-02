# Official policy pinned to controller v3.6.2; vendored for offline planning.
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.2/docs/install/iam_policy.json
resource "aws_iam_policy" "load_balancer_controller" {
  name        = "${var.project}-load-balancer-controller"
  description = "Official AWS Load Balancer Controller v3.6.2 policy"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.6.2.json")
}

resource "aws_iam_role" "load_balancer_controller" {
  name = "${var.project}-load-balancer-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster.arn
      }
      Condition = {
        StringEquals = {
          "${trimprefix(aws_iam_openid_connect_provider.cluster.url, "https://")}:aud" = "sts.amazonaws.com"
          "${trimprefix(aws_iam_openid_connect_provider.cluster.url, "https://")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

output "load_balancer_controller_role_arn" {
  description = "IRSA role for kube-system/aws-load-balancer-controller."
  value       = aws_iam_role.load_balancer_controller.arn
}
