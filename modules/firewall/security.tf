variable "egress_profile" {
  description = "compatibility (default) permits documented shared GitHub dependencies; restricted is an opt-in that allows only approved HTTPS FQDNs and requires filtering resolvers."
  type        = string
  default     = "compatibility"
  validation {
    condition     = contains(["compatibility", "restricted"], var.egress_profile)
    error_message = "Select compatibility or restricted."
  }
}

variable "approved_https_fqdns" {
  description = "Additional HTTPS destinations in compatibility mode; complete destination list in restricted mode. No protocol, path, port or universal wildcard."
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for fqdn in var.approved_https_fqdns :
      can(regex("^(\\*\\.)?[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$", fqdn))
    ])
    error_message = "Provide DNS hostnames or explicit wildcard subdomains, not URLs or a universal wildcard."
  }
}

variable "dns_resolver_ips" {
  description = "Approved external filtering resolver IPv4 addresses. Empty retains Azure DNS in compatibility mode only."
  type        = list(string)
  default     = []
  validation {
    condition = length(var.dns_resolver_ips) <= 3 && alltrue([
      for ip in var.dns_resolver_ips :
      can(cidrnetmask("${ip}/32")) && ip != "168.63.129.16" && ip != "0.0.0.0"
    ])
    error_message = "Provide up to three explicit IPv4 resolvers, not Azure platform DNS."
  }
}

variable "dns_policy_reference" {
  description = "Owner/policy reference for the external filtering resolver. Required in restricted mode; not proof of enforcement."
  type        = string
  default     = ""
}

variable "flow_logs" {
  description = "Optional existing regional Network Watcher and storage destination for VNet flow logs. Avoid duplicate externally managed logging."
  type = object({
    network_watcher_name                = string
    network_watcher_resource_group_name = string
    storage_account_id                  = string
    retention_days                      = number
  })
  default = null
  validation {
    condition = var.flow_logs == null ? true : (
      can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[^/]+$", var.flow_logs.storage_account_id)) &&
      var.flow_logs.retention_days >= 1 && var.flow_logs.retention_days <= 365 &&
      floor(var.flow_logs.retention_days) == var.flow_logs.retention_days &&
      length(trimspace(var.flow_logs.network_watcher_name)) > 0 &&
      length(trimspace(var.flow_logs.network_watcher_resource_group_name)) > 0
    )
    error_message = "Flow logs require an existing storage account, watcher, and 1-365 whole retention days."
  }
}

variable "diagnostics" {
  description = "Optional existing Log Analytics workspace or storage destination for firewall network, application and DNS decision logs. Retention belongs to the destination owner."
  type = object({
    log_analytics_workspace_id = optional(string)
    storage_account_id         = optional(string)
  })
  default = null
  validation {
    condition = var.diagnostics == null ? true : (
      (var.diagnostics.log_analytics_workspace_id != null || var.diagnostics.storage_account_id != null) &&
      (var.diagnostics.log_analytics_workspace_id == null ? true :
      can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+$", var.diagnostics.log_analytics_workspace_id))) &&
      (var.diagnostics.storage_account_id == null ? true :
      can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[^/]+$", var.diagnostics.storage_account_id)))
    )
    error_message = "Configure at least one correctly formed workspace/storage resource ID."
  }
}

resource "azurerm_network_watcher_flow_log" "runners" {
  count                = var.flow_logs == null ? 0 : 1
  name                 = "${var.base_name}-vnet-flow"
  location             = var.location
  network_watcher_name = var.flow_logs.network_watcher_name
  resource_group_name  = var.flow_logs.network_watcher_resource_group_name
  target_resource_id   = azurerm_virtual_network.vnet.id
  storage_account_id   = var.flow_logs.storage_account_id
  enabled              = true
  version              = 2
  retention_policy {
    enabled = true
    days    = var.flow_logs.retention_days
  }
}

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  count                      = var.diagnostics == null ? 0 : 1
  name                       = "${var.base_name}-firewall-diagnostics"
  target_resource_id         = azurerm_firewall.firewall.id
  log_analytics_workspace_id = var.diagnostics.log_analytics_workspace_id
  storage_account_id         = var.diagnostics.storage_account_id
  dynamic "enabled_log" {
    for_each = toset(["AzureFirewallNetworkRule", "AzureFirewallApplicationRule", "AzureFirewallDnsProxy"])
    content {
      category = enabled_log.value
    }
  }
}
