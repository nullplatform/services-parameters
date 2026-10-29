output "storage_configuration" {
  description = "Provider specification ID and the per-instance provider configs (id, nrn, dimensions), keyed by instance key."
  value = {
    specification_id = module.key_vault_spec.specification_id
    slug             = module.key_vault_spec.slug
    instances = {
      for key, instance in var.instances : key => {
        id         = module.key_vault_configuration[key].provider_config_id
        nrn        = instance.nrn
        dimensions = instance.dimensions
      }
    }
  }
}

output "notification_channels" {
  description = "Per-instance agent notification channels created (enable_notification_channel=true), keyed by instance key: id, nrn."
  value = {
    for key, instance in var.instances : key => {
      id  = module.key_vault_channels[key].notification_channel_id
      nrn = instance.nrn
    } if instance.enable_notification_channel
  }
}
