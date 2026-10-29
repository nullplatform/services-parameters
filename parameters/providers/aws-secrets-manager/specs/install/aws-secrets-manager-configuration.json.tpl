{
  "name": "AWS Secrets Manager",
  "description": "Stores nullplatform parameter values in AWS Secrets Manager",
  "slug": "aws-secrets-manager",
  "category": "parameters-storage",
  "icon": "mdi:aws",
  "visible_to": [
    "{{ env.Getenv "NRN" }}"
  ],
  "allow_dimensions": true,
  "schema": {
    "type": "object",
    "required": ["sensibility", "setup"],
    "additionalProperties": false,
    "properties": {
      "sensibility": {
        "type": "object",
        "order": 1,
        "required": ["applies_to"],
        "description": "The sensibility of the parameters stored in this backend.",
        "properties": {
          "applies_to": {
            "type": "array",
            "title": "Applies to",
            "description": "Which parameters this backend stores — secret, non-secret, or both.",
            "order": 1,
            "inline": true,
            "uniqueItems": true,
            "minItems": 1,
            "default": ["secret"],
            "items": {
              "oneOf": [
                { "const": "secret",     "title": "Secret parameters" },
                { "const": "non_secret", "title": "Non-secret parameters" }
              ]
            }
          }
        }
      },
      "setup": {
        "type": "object",
        "order": 2,
        "description": "The setup for the AWS Secrets Manager backend.",
        "properties": {
          "kms_key_id": {
            "type": "string",
            "title": "KMS Key ID",
            "description": "Customer-managed KMS key ARN or alias. If empty, the default aws/secretsmanager managed key is used",
            "default": "",
            "order": 1
          }
        }
      }
    }
  }
}
