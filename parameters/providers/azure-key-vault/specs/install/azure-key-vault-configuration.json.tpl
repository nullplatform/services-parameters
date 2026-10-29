{
  "name": "Azure Key Vault",
  "description": "Stores nullplatform parameter values in Azure Key Vault with native versioning",
  "slug": "azure-key-vault",
  "category": "parameters-storage",
  "icon": "mdi:microsoft-azure",
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
        "required": ["vault_name"],
        "description": "The setup for the Azure Key Vault backend.",
        "properties": {
          "vault_name": {
            "type": "string",
            "title": "Vault Name",
            "description": "Azure Key Vault name (without https:// or .vault.azure.net suffix)",
            "order": 1
          }
        }
      }
    }
  }
}
