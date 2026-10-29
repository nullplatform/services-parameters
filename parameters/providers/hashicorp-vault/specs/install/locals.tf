locals {
  # Attributes are passed straight to the parameter_storage_configuration module,
  # but null-valued optional keys are dropped: the spec schema types them as
  # strings (with their own defaults), so emitting `null` would fail server-side
  # validation. Each key is only included when set — kubernetes_role when
  # auth_mode = "kubernetes", namespace for the Vault Enterprise namespace, and
  # path_prefix when overriding the default KV prefix.
  instance_attributes = {
    for key, instance in var.instances : key => {
      sensibility = instance.attributes.sensibility
      setup = merge(
        {
          address   = instance.attributes.setup.address
          auth_mode = instance.attributes.setup.auth_mode
        },
        instance.attributes.setup.namespace == null ? {} : {
          namespace = instance.attributes.setup.namespace
        },
        instance.attributes.setup.path_prefix == null ? {} : {
          path_prefix = instance.attributes.setup.path_prefix
        },
        instance.attributes.setup.kubernetes_role == null ? {} : {
          kubernetes_role = instance.attributes.setup.kubernetes_role
        }
      )
    }
  }
}
