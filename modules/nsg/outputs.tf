output "network_settings_id" {
  description = "ID of the GitHub.Network/networkSettings resource"
  value       = jsondecode(azapi_resource.github_network_settings.output).tags.GitHubId
}

output "runner_network_security_group_id" {
  description = "ID of the runner subnet network security group"
  value       = azurerm_network_security_group.actions_nsg.id
}

output "runner_subnet_id" {
  description = "ID of the delegated runner subnet"
  value       = azurerm_subnet.runner_subnet.id
}

output "virtual_network_id" {
  description = "VNet ID for externally managed diagnostics or flow logs."
  value       = azurerm_virtual_network.vnet.id
}

output "flow_log_ids" {
  description = "Configured VNet flow log IDs; empty when managed externally."
  value       = azurerm_network_watcher_flow_log.runners[*].id
}

output "runner_security_rules" {
  description = "Configured runner NSG rules for policy inspection."
  value       = azurerm_network_security_group.actions_nsg.security_rule
}
