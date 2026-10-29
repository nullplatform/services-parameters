locals {
  iam_enabled    = var.iam_role.enable
  aws_account_id = local.iam_enabled ? data.aws_caller_identity.current[0].account_id : ""
  aws_region     = local.iam_enabled ? data.aws_region.current[0].region : ""

  trusted_principals = (
    length(var.iam_role.trusted_principals) > 0 ?
    # allow to specify an allowlist of roles that can assume the created role
    var.iam_role.trusted_principals :
    # when no allowlist provided, any role from the same account can assume it
    ["arn:aws:iam::${local.aws_account_id}:root"]
  )

  effective_trusted_principals = local.iam_enabled ? local.trusted_principals : []

  base_policy_statement = {
    Sid    = "ManageNullplatformParameters"
    Effect = "Allow"
    Action = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:DeleteParameter",
    ]
    Resource = "arn:aws:ssm:${local.aws_region}:${local.aws_account_id}:parameter/nullplatform/*"
  }

  kms_policy_statement = {
    Sid    = "UseCustomerManagedKmsKey"
    Effect = "Allow"
    Action = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    Resource = var.iam_role.kms_key_arn
    Condition = {
      StringEquals = {
        "kms:ViaService" = "ssm.${local.aws_region}.amazonaws.com"
      }
    }
  }

  policy_doc = var.iam_role.mode == "kms" ? jsonencode({
    Version   = "2012-10-17"
    Statement = [local.base_policy_statement, local.kms_policy_statement]
    }) : jsonencode({
    Version   = "2012-10-17"
    Statement = [local.base_policy_statement]
  })
}