{
  "name": "GCP Secret Manager",
  "description": "Stores nullplatform parameter values in Google Cloud Secret Manager with native versioning",
  "slug": "gcp-secret-manager",
  "category": "parameters-storage",
  "icon": "mdi:google-cloud",
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
        "required": ["project_id"],
        "description": "The setup for the GCP Secret Manager backend.",
        "properties": {
          "project_id": {
            "type": "string",
            "title": "Project ID",
            "description": "GCP project that holds the secrets",
            "order": 1
          },
          "name_prefix": {
            "type": "string",
            "title": "Name prefix",
            "description": "Prefix of every secret id this backend creates (letters, digits, '_' and '-', without '__', which separates the id segments). The agent's IAM condition is scoped to it.",
            "pattern": "^_?[A-Za-z0-9-]+(_[A-Za-z0-9-]+)*_?$",
            "default": "nullplatform",
            "order": 2
          },
          "replica_locations": {
            "type": "array",
            "title": "Replica locations",
            "description": "Regions to replicate each secret to (user-managed replication, e.g. for data residency). Leave empty for automatic replication.",
            "uniqueItems": true,
            "items": { "type": "string" },
            "order": 3
          }
        }
      }
    }
  }
}
