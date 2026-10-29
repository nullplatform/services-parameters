{
  "name": "My Service",
  "slug": "my-service",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "available_links": ["connect"],
  "selectors": {
    "category": "Other",
    "imported": false,
    "provider": "AWS",
    "sub_category": "Other"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [],
      "properties": {
        "example": {
          "type": "string",
          "title": "Example",
          "description": "Replace with the attributes users fill in when creating the service",
          "editableOn": ["create", "update"],
          "order": 1
        }
      }
    },
    "values": {}
  }
}
