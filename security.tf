variable "egress_profile" {
  description = "compatibility (default) permits dynamic public HTTPS; restricted is an opt-in that allows only approved public CIDRs and requires filtering resolvers."
  type        = string
  default     = "compatibility"
}

variable "approved_public_egress_cidrs" {
  description = "Explicit restricted-mode public HTTPS destinations. NSGs cannot enforce FQDN or account ownership."
  type        = list(string)
  default     = []
}

variable "dns_resolver_ips" {
  description = "Approved external filtering resolver IPv4 addresses."
  type        = list(string)
  default     = []
}

variable "dns_policy_reference" {
  description = "Owner/policy reference for the external filtering resolver."
  type        = string
  default     = ""
}

variable "flow_logs" {
  description = "Optional existing Network Watcher and storage configuration for VNet flow logs."
  type = object({
    network_watcher_name                = string
    network_watcher_resource_group_name = string
    storage_account_id                  = string
    retention_days                      = number
  })
  default = null
}
