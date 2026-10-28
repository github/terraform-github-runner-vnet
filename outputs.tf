output "gh_network_settings_resource_id" {
  description = "ID of the GitHub.Network/networkSettings resource"
  value       = module.vnet.network_settings_id
}

output "runner_network_security_group_id" {
  description = "ID of the runner subnet network security group"
  value       = module.vnet.runner_network_security_group_id
}

output "runner_subnet_id" {
  description = "ID of the delegated runner subnet"
  value       = module.vnet.runner_subnet_id
}

output "virtual_network_id" {
  description = "VNet ID for externally managed diagnostics or flow logs."
  value       = module.vnet.virtual_network_id
}

output "flow_log_ids" {
  description = "Configured VNet flow log IDs."
  value       = module.vnet.flow_log_ids
}
