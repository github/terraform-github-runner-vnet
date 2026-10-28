terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.11.0, < 6.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.14.0"
    }
  }
}

locals {
  rg_name = "${var.base_name}-rg"
  ns_name = "${var.base_name}-ns"

  dns_deny_rules = {
    platform = { priority = 103, port = "*", destination = "AzurePlatformDNS" }
    other    = { priority = 104, port = "53", destination = "*" }
  }
}

# You need this if you haven't already registered the GitHub.Network resource provider in your Azure subscription.
# Terraform doesn't manage this type of create-once-and-never-delete resource very well, so I've just commented it out.
# Even with the lifecycle/prevent_destroy, it will still throw an error if you delete the resources manually with "terraform destroy".

# resource "azurerm_resource_provider_registration" "github_network_provider" {
#   name = "GitHub.Network"
#   lifecycle {
#     prevent_destroy = true
#   }
# }

resource "azurerm_resource_group" "resource_group" {
  location = var.location
  name     = local.rg_name
}

resource "azurerm_network_security_group" "actions_nsg" {
  name                = "${var.base_name}-actions-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name

  security_rule {
    name                       = "DenyInboundRunnerTraffic"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                         = "DenyRunnerPeerOutbound"
    priority                     = 100
    direction                    = "Outbound"
    access                       = "Deny"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_range       = "*"
    source_address_prefix        = "*"
    destination_address_prefixes = var.runner_subnet_address_prefixes
  }

  dynamic "security_rule" {
    for_each = length(var.dns_resolver_ips) == 0 ? {} : { tcp = "Tcp", udp = "Udp" }
    content {
      name                         = "AllowApprovedDNS-${security_rule.key}"
      priority                     = security_rule.key == "tcp" ? 101 : 102
      direction                    = "Outbound"
      access                       = "Allow"
      protocol                     = security_rule.value
      source_port_range            = "*"
      destination_port_range       = "53"
      source_address_prefix        = "*"
      destination_address_prefixes = var.dns_resolver_ips
    }
  }

  dynamic "security_rule" {
    for_each = length(var.dns_resolver_ips) == 0 ? {} : local.dns_deny_rules
    content {
      name                       = "DenyDNS-${security_rule.key}"
      priority                   = security_rule.value.priority
      direction                  = "Outbound"
      access                     = "Deny"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = "*"
      destination_address_prefix = security_rule.value.destination
    }
  }

  dynamic "security_rule" {
    for_each = var.approved_private_service_rules
    content {
      name                         = "AllowPrivateService-${security_rule.value.name}"
      priority                     = 110 + security_rule.key
      direction                    = "Outbound"
      access                       = "Allow"
      protocol                     = security_rule.value.protocol
      source_port_range            = "*"
      destination_port_ranges      = security_rule.value.destination_port_ranges
      source_address_prefix        = "*"
      destination_address_prefixes = security_rule.value.destination_address_prefixes
    }
  }

  dynamic "security_rule" {
    for_each = var.egress_profile == "restricted" && length(var.approved_public_egress_cidrs) > 0 ? [1] : []
    content {
      name                         = "AllowApprovedPublicHTTPS"
      priority                     = 240
      direction                    = "Outbound"
      access                       = "Allow"
      protocol                     = "Tcp"
      source_port_range            = "*"
      destination_port_range       = "443"
      source_address_prefix        = "*"
      destination_address_prefixes = var.approved_public_egress_cidrs
    }
  }

  dynamic "security_rule" {
    for_each = var.egress_profile == "compatibility" ? [1] : []
    content {
      name                       = "AllowPublicHTTPSCompatibility"
      priority                   = 240
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = "*"
      destination_address_prefix = "Internet"
    }
  }

  security_rule {
    name                   = "DenyVirtualNetworkOutbound"
    priority               = 200
    direction              = "Outbound"
    access                 = "Deny"
    protocol               = "*"
    source_port_range      = "*"
    destination_port_range = "*"
    source_address_prefix  = "*"
    # VirtualNetwork can include a consumer-managed 0/0 UDR and inadvertently deny public GitHub traffic.
    destination_address_prefixes = var.vnet_address_space
  }

  security_rule {
    name                         = "DenyOtherPrivateNetworks"
    priority                     = 201
    direction                    = "Outbound"
    access                       = "Deny"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_range       = "*"
    source_address_prefix        = "*"
    destination_address_prefixes = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  dynamic "security_rule" {
    for_each = length(var.additional_private_address_prefixes) == 0 ? [] : [1]
    content {
      name                         = "DenyAdditionalPrivateNetworks"
      priority                     = 202
      direction                    = "Outbound"
      access                       = "Deny"
      protocol                     = "*"
      source_port_range            = "*"
      destination_port_range       = "*"
      source_address_prefix        = "*"
      destination_address_prefixes = var.additional_private_address_prefixes
    }
  }

  security_rule {
    name                       = "DenyInternetOutBoundOverwrite"
    priority                   = 400
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  lifecycle {
    precondition {
      condition     = var.egress_profile != "restricted" || (length(var.dns_resolver_ips) > 0 && length(trimspace(var.dns_policy_reference)) > 0)
      error_message = "Restricted mode requires approved filtering resolvers and their owner/policy reference."
    }
  }
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.base_name}-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  address_space       = var.vnet_address_space
  dns_servers         = var.dns_resolver_ips
}

resource "azurerm_subnet" "runner_subnet" {
  name                 = "${var.base_name}-runner-subnet"
  resource_group_name  = azurerm_resource_group.resource_group.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.runner_subnet_address_prefixes
  delegation {
    name = "delegation"
    service_delegation {
      name    = "GitHub.Network/networkSettings"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azapi_resource" "github_network_settings" {
  type                      = "GitHub.Network/networkSettings@2024-04-02"
  name                      = "${local.ns_name}-deployment"
  location                  = var.location
  parent_id                 = azurerm_resource_group.resource_group.id
  schema_validation_enabled = false
  body = jsonencode({
    properties = {
      businessId = var.github_business_id
      subnetId   = azurerm_subnet.runner_subnet.id
    }
  })
  response_export_values = ["tags.GitHubId"]
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg_association" {
  subnet_id                 = azurerm_subnet.runner_subnet.id
  network_security_group_id = azurerm_network_security_group.actions_nsg.id
}
