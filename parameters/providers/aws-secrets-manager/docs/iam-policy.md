# IAM Policy

Minimum IAM permissions for `parameters/providers/aws-secrets-manager/`. Scoped to the `nullplatform/*` namespace so the agent cannot reach any secret outside this provider's domain.

---

## Required actions

| Action                            | Used by    | Why                                                 |
|-----------------------------------|------------|-----------------------------------------------------|
| `secretsmanager:CreateSecret`     | `store`    | Creates the secret on the first version             |
| `secretsmanager:PutSecretValue`   | `store`    | Adds a new version when the secret already exists   |
| `secretsmanager:GetSecretValue`   | `retrieve` | Reads the current value                             |
| `secretsmanager:DeleteSecret`     | `delete`   | Removes the secret entirely                         |

---

## Recommended policy

Replace `<AWS_REGION>` and `<AWS_ACCOUNT_ID>` before applying. The `nullplatform/*` resource pattern restricts the agent to secrets created and managed by this provider.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageNullplatformParameters",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DeleteSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:<AWS_REGION>:<AWS_ACCOUNT_ID>:secret:nullplatform/*"
      ]
    }
  ]
}
```

The trailing `*` in the resource ARN absorbs both the path under `nullplatform/` and the random 6-character suffix AWS SM appends to every secret ARN.

---

## KMS (only if using a customer-managed key)

If the provider's configuration sets `kms_key_id` to a customer-managed key (rather than the default `aws/secretsmanager`), the agent also needs KMS permissions on that key:

```json
{
  "Sid": "UseCustomerManagedKmsKey",
  "Effect": "Allow",
  "Action": [
    "kms:Decrypt",
    "kms:GenerateDataKey"
  ],
  "Resource": [
    "arn:aws:kms:<AWS_REGION>:<AWS_ACCOUNT_ID>:key/<KMS_KEY_ID>"
  ],
  "Condition": {
    "StringEquals": {
      "kms:ViaService": "secretsmanager.<AWS_REGION>.amazonaws.com"
    }
  }
}
```

`kms:ViaService` restricts the key to SSM use only — without it, the role could decrypt arbitrary ciphertexts encrypted with the same key.

The CMK's **key policy** must also allow the role principal. IAM permissions alone are not enough for KMS.
