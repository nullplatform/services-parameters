resource "aws_iam_role" "this" {
  count = local.iam_enabled ? 1 : 0
  name  = var.iam_role.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = local.effective_trusted_principals
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "this" {
  count  = local.iam_enabled ? 1 : 0
  name   = "${var.iam_role.name}-policy"
  role   = aws_iam_role.this[0].name
  policy = local.policy_doc
}
