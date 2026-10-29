{
  "name": "HashiCorp Vault",
  "description": "Stores nullplatform parameter values in HashiCorp Vault KV v2 with native versioning",
  "slug": "hashicorp-vault",
  "category": "parameters-storage",
  "icon": "simple-icons:vault",
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
            "default": ["secret", "non_secret"],
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
        "required": ["address", "auth_mode"],
        "description": "The setup for the HashiCorp Vault backend.",
        "properties": {
          "address": {
            "type": "string",
            "title": "Vault Address",
            "description": "Vault HTTP(S) endpoint (e.g. https://vault.example.com:8200)",
            "order": 1
          },
          "namespace": {
            "type": "string",
            "title": "Namespace",
            "description": "Vault Enterprise namespace the parameters live under (e.g. admin/eks-null-alfa-136). Leave empty for the root namespace (Vault OSS / single-namespace). The login and every read/write target this namespace.",
            "order": 2
          },
          "path_prefix": {
            "type": "string",
            "title": "KV path prefix",
            "description": "KV v2 path prefix (relative to the namespace) parameters are stored under. Must be the full `<mount>/data/<subpath>` including the mount name and the KV v2 `data` segment (e.g. secret/data/nullplatform).",
            "order": 3,
            "default": "secret/data/nullplatform"
          },
          "auth_mode": {
            "type": "string",
            "title": "Authentication mode",
            "description": "How the nullplatform agent authenticates to Vault.",
            "order": 4,
            "default": "userpass",
            "oneOf": [
              { "const": "userpass",   "title": "Username and password" },
              { "const": "kubernetes", "title": "Kubernetes (pod identity)" }
            ]
          },
          "kubernetes_role": {
            "type": "string",
            "title": "Vault Kubernetes role",
            "description": "Name of the Vault Kubernetes auth role bound to the agent's ServiceAccount. Required when the authentication mode is Kubernetes.",
            "order": 5
          }
        },
        "allOf": [
          {
            "if": { "properties": { "auth_mode": { "const": "kubernetes" } } },
            "then": { "required": ["kubernetes_role"] }
          }
        ]
      }
    },
    "uiSchema": {
      "type": "VerticalLayout",
      "elements": [
        {
          "type": "Control",
          "scope": "#/properties/sensibility/properties/applies_to"
        },
        {
          "type": "Control",
          "scope": "#/properties/setup/properties/address"
        },
        {
          "type": "Control",
          "scope": "#/properties/setup/properties/namespace"
        },
        {
          "type": "Control",
          "scope": "#/properties/setup/properties/path_prefix"
        },
        {
          "type": "Control",
          "scope": "#/properties/setup/properties/auth_mode",
          "options": { "format": "radio-cards" }
        },
        {
          "type": "Label",
          "text": "> **ℹ️ Username / password authentication**\n\nCredentials are **not** stored in this configuration — the password is sensitive, so both values are read from environment variables in the nullplatform agent runtime:\n\n- **`VAULT_USERNAME`** — the Vault `userpass` username\n- **`VAULT_PASSWORD`** — the user's password (sensitive)\n\nSet both as environment variables in your agent Helm installation. The agent exchanges them for a short-lived Vault token on every run. The user must have a Vault policy granting read/write on `secret/data/nullplatform/*`. See the provider README for the full Vault setup.",
          "options": { "format": "markdown" },
          "rule": {
            "effect": "HIDE",
            "condition": {
              "scope": "#/properties/setup/properties/auth_mode",
              "schema": { "not": { "const": "userpass" } }
            }
          }
        },
        {
          "type": "Control",
          "scope": "#/properties/setup/properties/kubernetes_role",
          "rule": {
            "effect": "HIDE",
            "condition": {
              "scope": "#/properties/setup/properties/auth_mode",
              "schema": { "not": { "const": "kubernetes" } }
            }
          }
        },
        {
          "type": "Label",
          "text": "> **ℹ️ Kubernetes authentication (pod identity)**\n\nThe agent authenticates with its **Kubernetes ServiceAccount identity** — no secrets to configure. It reads the projected ServiceAccount token and exchanges it for a Vault token bound to the **Vault role** above.\n\nThis requires one-time setup on both Vault and the cluster:\n\n- Enable and configure the `kubernetes` auth method on Vault (`vault auth enable kubernetes`)\n- Create a Vault policy granting read/write on `secret/data/nullplatform/*`\n- Create a Vault role that binds the agent's ServiceAccount (name + namespace) to that policy\n\nProvision the cluster-side resources with the `specs/requirements/` module. See the provider README for the exact Vault + cluster commands.",
          "options": { "format": "markdown" },
          "rule": {
            "effect": "HIDE",
            "condition": {
              "scope": "#/properties/setup/properties/auth_mode",
              "schema": { "not": { "const": "kubernetes" } }
            }
          }
        }
      ]
    }
  }
}
