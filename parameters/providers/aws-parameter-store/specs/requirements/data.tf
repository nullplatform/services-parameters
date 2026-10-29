data "aws_caller_identity" "current" {
  count = var.iam_role.enable ? 1 : 0
}

data "aws_region" "current" {
  count = var.iam_role.enable ? 1 : 0
}
