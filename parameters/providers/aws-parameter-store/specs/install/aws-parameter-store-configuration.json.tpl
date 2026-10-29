{
  "name": "AWS Parameter Store",
  "description": "Stores nullplatform parameter values in AWS SSM Parameter Store",
  "slug": "aws-parameter-store",
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
            "default": ["non_secret"],
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
        "description": "The setup for the AWS Parameter Store backend.",
        "properties": {
          "kms_key_id": {
            "type": "string",
            "title": "KMS Key ID",
            "description": "Customer-managed KMS key for SecureString parameters. If empty, the default alias/aws/ssm key is used",
            "default": "",
            "order": 1
          },
          "tier": {
            "type": "string",
            "title": "Parameter Tier",
            "description": "Standard is free for up to 10,000 parameters. Advanced supports larger values but costs $0.05/param/month",
            "default": "Standard",
            "order": 2,
            "oneOf": [
              { "const": "Standard",            "title": "Standard (free)" },
              { "const": "Advanced",            "title": "Advanced ($0.05/param/month)" },
              { "const": "Intelligent-Tiering", "title": "Intelligent-Tiering" }
            ]
          }
        }
      }
    }
  }
}
