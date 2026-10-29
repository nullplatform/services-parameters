module "key_vault_spec" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/parameter_storage_definition?ref=v6.3.0"

  nrn                                      = var.nrn
  np_api_key                               = var.np_api_key
  extra_visible_to_nrns                    = var.extra_visible_to_nrns
  template_path                            = var.template_path
  repository_parameter_storage_spec_branch = var.repository_parameter_storage_spec_branch
  repository_parameter_storage_spec        = var.repository_parameter_storage_spec
}

module "key_vault_api_keys" {
  source   = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/api_key?ref=v6.3.0"
  for_each = { for key, instance in var.instances : key => instance if instance.enable_notification_channel }

  type               = "agent"
  nrn                = each.value.nrn
  specification_slug = "parameter_storage"
}

module "key_vault_configuration" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/parameter_storage_configuration?ref=v6.3.0"

  for_each = var.instances

  nrn                         = each.value.nrn
  np_api_key                  = var.np_api_key
  provider_specification_slug = module.key_vault_spec.slug
  dimensions                  = each.value.dimensions
  attributes                  = each.value.attributes

  depends_on = [module.key_vault_spec]
}

module "key_vault_channels" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/parameter_storage_definition_agent_association?ref=v6.3.0"

  for_each = { for key, instance in var.instances : key => instance if instance.enable_notification_channel }

  nrn            = each.value.nrn
  api_key        = module.key_vault_api_keys[each.key].api_key
  tags_selectors = each.value.tags_selectors

  depends_on = [module.key_vault_spec]
}
