variable "egress_profile" {
  description = "compatibility (default) permits public HTTPS for dynamic GitHub dependencies; restricted is an opt-in that allows only approved public CIDRs and requires filtering resolvers."
  type        = string
  default     = "compatibility"
  validation {
    condition     = contains(["compatibility", "restricted"], var.egress_profile)
    error_message = "Select compatibility or restricted."
  }
}

variable "approved_public_egress_cidrs" {
  description = "Explicit IPv4 public HTTPS destinations for restricted mode, including any approved storage endpoints. NSGs cannot verify account ownership."
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for prefix in var.approved_public_egress_cidrs :
      can(cidrnetmask(prefix)) && try(tonumber(split("/", prefix)[1]) > 0, false)
    ])
    error_message = "Provide bounded IPv4 CIDRs."
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
