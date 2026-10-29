################################################################################
# Optional: IAM role with least-privilege permissions for this provider.
# Toggle with var.iam_role.enable. Outputs the role ARN so operators can wire
# it into the identity-access-control provider config (selector="secret_manager").
################################################################################

data "aws_caller_identity" "current" {
  count = var.iam_role.enable ? 1 : 0
}

data "aws_region" "current" {
  count = var.iam_role.enable ? 1 : 0
}
