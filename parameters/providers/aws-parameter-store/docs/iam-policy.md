# IAM Policy

Minimum IAM permissions for `parameters/providers/aws-parameter-store/`. Scoped to the `nullplatform/*` namespace so the agent cannot reach any parameter outside this provider's domain.

---

## Required actions

| Action                       | Used by    | Why                                                    |
|------------------------------|------------|--------------------------------------------------------|
| `ssm:PutParameter`           | `store`    | Creates the parameter (String or SecureString)         |
| `ssm:GetParameter`           | `retrieve` | Reads the value back                                   |
| `ssm:DeleteParameter`        | `delete`   | Removes the parameter                                  |

---

## Recommended policy

Replace `<AWS_REGION>` and `<AWS_ACCOUNT_ID>` before applying. The `nullplatform/*` resource pattern restricts the agent to parameters created and managed by this provider.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageNullplatformParameters",
      "Effect": "Allow",
      "Action": [
        "ssm:PutParameter",
        "ssm:GetParameter",
        "ssm:DeleteParameter"
      ],
      "Resource": [
        "arn:aws:ssm:<AWS_REGION>:<AWS_ACCOUNT_ID>:parameter/nullplatform/*"
      ]
    }
  ]
}
```

---

## KMS (only when storing SecureString with a CMK)

If the provider's configuration sets `kms_key_id` to a customer-managed key (rather than the default `alias/aws/ssm`), the agent also needs KMS permissions on that key:

```json
{
  "Sid": "UseCustomerManagedKmsKeyForParameterStore",
  "Effect": "Allow",
  "Action": [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:GenerateDataKey"
  ],
  "Resource": [
    "arn:aws:kms:<AWS_REGION>:<AWS_ACCOUNT_ID>:key/<KMS_KEY_ID>"
  ],
  "Condition": {
    "StringEquals": {
      "kms:ViaService": "ssm.<AWS_REGION>.amazonaws.com"
    }
  }
}
```

The `kms:ViaService` condition restricts the key to SSM use — without it, the role could decrypt arbitrary ciphertexts encrypted with the same key. The CMK's **key policy** must also allow the role principal; IAM permissions alone aren't enough for KMS.

If you use the default `alias/aws/ssm` (AWS-managed), no extra KMS statement is needed — Parameter Store handles encryption transparently.

---

## Splitting agent vs consumer

The writer (this provider's scripts) needs put + get + delete. A runtime consumer typically only needs read:

```json
{
  "Sid": "ReadNullplatformParameters",
  "Effect": "Allow",
  "Action": [
    "ssm:GetParameter",
    "ssm:GetParameters",
    "ssm:GetParametersByPath"
  ],
  "Resource": [
    "arn:aws:ssm:<AWS_REGION>:<AWS_ACCOUNT_ID>:parameter/nullplatform/*"
  ]
}
```

`GetParametersByPath` is useful if a consumer wants to enumerate all parameters under a hierarchical prefix (e.g. fetching all secrets for an app in one call).

---

## What not to grant

- `ssm:*` (account-wide) — opens access to OS commands (`AWS-RunShellScript`), maintenance windows, session manager, etc.
- `ssm:PutParameter` with `Resource: "*"` — lets the role write to ANY parameter in the account (including other apps' secrets).
- `ssm:LabelParameterVersion`, `ssm:UnlabelParameterVersion` — versioning workflows; not used by this provider.
- `iam:*` — this provider doesn't manage IAM.
