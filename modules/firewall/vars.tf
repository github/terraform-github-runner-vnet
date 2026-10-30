variable "base_name" {
  description = "Base name for resources"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = list(string)
  default     = ["10.0.0.0/16"]

  validation {
    condition     = length(var.vnet_address_space) > 0 && alltrue([for prefix in var.vnet_address_space : can(cidrnetmask(prefix))])
    error_message = "Provide IPv4 CIDR prefixes; GitHub-hosted runners on Azure private networking are IPv4-only."
  }
}

variable "runner_subnet_address_prefixes" {
  description = "Address prefixes for the runner subnet"
  type        = list(string)
  default     = ["10.0.0.0/24"]

  validation {
    condition     = length(var.runner_subnet_address_prefixes) > 0 && alltrue([for prefix in var.runner_subnet_address_prefixes : can(cidrnetmask(prefix))])
    error_message = "Provide IPv4 CIDR prefixes; GitHub-hosted runners on Azure private networking are IPv4-only."
  }
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

  validation {
    condition = length(var.approved_private_service_rules) <= 80 && length(distinct([
      for rule in var.approved_private_service_rules : rule.name
    ])) == length(var.approved_private_service_rules)
    error_message = "Use at most 80 uniquely named private-service rules."
  }

  validation {
    condition = alltrue([
      for rule in var.approved_private_service_rules :
      length(trimspace(rule.name)) > 0 &&
      length(rule.name) <= 60 &&
      can(regex("^[A-Za-z0-9_.-]+$", rule.name)) &&
      length(rule.destination_address_prefixes) > 0 &&
      alltrue([
        for prefix in rule.destination_address_prefixes :
        can(cidrnetmask(prefix)) && try(tonumber(split("/", prefix)[1]) > 0, false)
      ]) &&
      length(rule.destination_port_ranges) > 0 &&
      alltrue([
        for port_range in rule.destination_port_ranges :
        can(regex("^[0-9]{1,5}(-[0-9]{1,5})?$", port_range)) &&
        try(
          tonumber(split("-", port_range)[0]) >= 1 &&
          tonumber(split("-", port_range)[0]) <= 65535 &&
          tonumber(try(split("-", port_range)[1], split("-", port_range)[0])) >= tonumber(split("-", port_range)[0]) &&
          tonumber(try(split("-", port_range)[1], split("-", port_range)[0])) <= 65535,
          false
        )
      ]) &&
      contains(["Tcp", "Udp", "*"], rule.protocol)
    ])
    error_message = "Private-service rules require named IPv4 CIDR destinations, explicit port ranges, and a valid protocol."
  }

  validation {
    condition = alltrue([
      for rule in var.approved_private_service_rules : alltrue(flatten([
        for sorted_intervals in [sort([
          for prefix in rule.destination_address_prefixes : format("%010d %010d",
            sum([for index, octet in split(".", cidrhost(prefix, 0)) : tonumber(octet) * pow(256, 3 - index)]),
            sum([for index, octet in split(".", cidrhost(prefix, 0)) : tonumber(octet) * pow(256, 3 - index)]) + pow(2, 32 - tonumber(split("/", prefix)[1])) - 1
          ) if can(cidrnetmask(prefix))
          ])] : [
          for position, interval in sorted_intervals :
          position == 0 || tonumber(split(" ", interval)[0]) > tonumber(split(" ", sorted_intervals[max(position - 1, 0)])[1])
        ]
      ]))
    ])
    error_message = "Destination prefixes within a private-service rule must not overlap; Azure rejects overlapping prefixes in one rule."
  }
}

variable "firewall_subnet_address_prefixes" {
  description = "Address prefixes for the firewall subnet"
  type        = list(string)
  default     = ["10.0.1.0/26"]

  validation {
    condition     = length(var.firewall_subnet_address_prefixes) > 0 && alltrue([for prefix in var.firewall_subnet_address_prefixes : can(cidrnetmask(prefix))])
    error_message = "Provide IPv4 CIDR prefixes; GitHub-hosted runners on Azure private networking are IPv4-only."
  }
}

variable "firewall_management_subnet_address_prefixes" {
  description = "Address prefixes for the management subnet"
  type        = list(string)
  default     = ["10.0.2.0/26"]

  validation {
    condition     = length(var.firewall_management_subnet_address_prefixes) > 0 && alltrue([for prefix in var.firewall_management_subnet_address_prefixes : can(cidrnetmask(prefix))])
    error_message = "Provide IPv4 CIDR prefixes; GitHub-hosted runners on Azure private networking are IPv4-only."
  }
}

variable "github_business_id" {
  description = "GitHub Enterprise or Organization Database ID"
  type        = string
}

variable "additional_private_address_prefixes" {
  description = "Additional local or peered address prefixes (for example non-RFC1918 peerings) denied after approved private-service exceptions. Must not overlap each other."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for prefix in var.additional_private_address_prefixes :
      can(cidrnetmask(prefix)) && try(tonumber(split("/", prefix)[1]) > 0, false)
    ])
    error_message = "Provide bounded IPv4 CIDR prefixes, not 0.0.0.0/0."
  }

  validation {
    condition = alltrue(flatten([
      for sorted_intervals in [sort([
        for prefix in var.additional_private_address_prefixes : format("%010d %010d",
          sum([for index, octet in split(".", cidrhost(prefix, 0)) : tonumber(octet) * pow(256, 3 - index)]),
          sum([for index, octet in split(".", cidrhost(prefix, 0)) : tonumber(octet) * pow(256, 3 - index)]) + pow(2, 32 - tonumber(split("/", prefix)[1])) - 1
        ) if can(cidrnetmask(prefix))
        ])] : [
        for position, interval in sorted_intervals :
        position == 0 || tonumber(split(" ", interval)[0]) > tonumber(split(" ", sorted_intervals[max(position - 1, 0)])[1])
      ]
    ]))
    error_message = "Additional private prefixes must not overlap; Azure rejects overlapping prefixes in one rule."
  }
}
