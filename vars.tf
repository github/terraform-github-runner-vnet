variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "base_name" {
  description = "Base name for resources"
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "runner_subnet_address_prefixes" {
  description = "Address prefixes for the runner subnet"
  type        = list(string)
  default     = ["10.0.0.0/24"]
}

variable "approved_private_service_rules" {
  description = "Explicit private destination CIDRs, ports, and protocols runners may access. Runner subnet destinations are always denied."
  type = list(object({
    name                         = string
    destination_address_prefixes = list(string)
    destination_port_ranges      = list(string)
    protocol                     = string
  }))
  default  = []
  nullable = false
}

variable "github_business_id" {
  description = "GitHub Enterprise or Organization Database ID"
  type        = string
}

variable "additional_private_address_prefixes" {
  description = "Additional local or peered address prefixes denied after approved private-service exceptions."
  type        = list(string)
  default     = []
  nullable    = false
}
