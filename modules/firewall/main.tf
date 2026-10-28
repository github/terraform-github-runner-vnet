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

  compatibility_https_fqdns = [
    "github.com",
    "api.github.com",
    "*.actions.githubusercontent.com",
    "objects.githubusercontent.com",
    "objects-origin.githubusercontent.com",
    "github-releases.githubusercontent.com",
    "github-registry-files.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "codeload.github.com",
    "cafe.github.com",
    "*.blob.core.windows.net",
    "ghcr.io",
    "*.ghcr.io",
    "*.pkg.github.com",
    "*.githubassets.com",
    "github-cloud.s3.amazonaws.com"
  ]
  https_fqdns = distinct(concat(
    var.egress_profile == "compatibility" ? local.compatibility_https_fqdns : [],
    var.approved_https_fqdns
  ))

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

resource "azurerm_virtual_network" "vnet" {
  address_space       = var.vnet_address_space
  location            = var.location
  name                = "${var.base_name}-vnet"
  resource_group_name = azurerm_resource_group.resource_group.name
  dns_servers         = var.dns_resolver_ips
  depends_on = [
    azurerm_resource_group.resource_group
  ]
}

resource "azurerm_subnet" "firewall_subnet" {
  address_prefixes = var.firewall_subnet_address_prefixes
  # The subnet name has to be exactly this, in order for the subnet to be used for a firewall
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.resource_group.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  depends_on = [
    azurerm_virtual_network.vnet
  ]
}

resource "azurerm_subnet" "management_subnet" {
  address_prefixes = var.firewall_management_subnet_address_prefixes
  # The subnet name has to be exactly this in order for the subnet to be used for the firewall management
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.resource_group.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  depends_on = [
    azurerm_virtual_network.vnet
  ]
}

resource "azurerm_subnet" "runner_subnet" {
  address_prefixes     = var.runner_subnet_address_prefixes
  name                 = "${var.base_name}-runner-subnet"
  resource_group_name  = azurerm_resource_group.resource_group.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  delegation {
    name = "GitHub.Network.networkSettings"
    service_delegation {
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      name    = "GitHub.Network/networkSettings"
    }
  }
  depends_on = [
    azurerm_virtual_network.vnet
  ]
}

resource "azurerm_network_security_group" "runner_nsg" {
  name                = "${var.base_name}-runner-nsg"
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

  security_rule {
    name                   = "DenyVirtualNetworkOutbound"
    priority               = 200
    direction              = "Outbound"
    access                 = "Deny"
    protocol               = "*"
    source_port_range      = "*"
    destination_port_range = "*"
    source_address_prefix  = "*"
    # VirtualNetwork can include the 0/0 UDR and inadvertently deny public GitHub traffic.
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

  lifecycle {
    precondition {
      condition = var.egress_profile != "restricted" || (
        length(var.dns_resolver_ips) > 0 && length(trimspace(var.dns_policy_reference)) > 0 &&
        length(var.approved_https_fqdns) > 0
      )
      error_message = "Restricted mode requires approved HTTPS FQDNs, filtering resolvers and their owner/policy reference."
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "runner_subnet_nsg_association" {
  subnet_id                 = azurerm_subnet.runner_subnet.id
  network_security_group_id = azurerm_network_security_group.runner_nsg.id
}

resource "azurerm_public_ip" "firewall_public_ip" {
  allocation_method   = "Static"
  location            = var.location
  name                = "${var.base_name}-firewall-ip"
  resource_group_name = azurerm_resource_group.resource_group.name
  sku                 = "Standard"
  depends_on = [
    azurerm_resource_group.resource_group,
  ]
}

resource "azurerm_public_ip" "firewall_management_public_ip" {
  allocation_method   = "Static"
  location            = var.location
  name                = "${var.base_name}-firewall-mgmt-ip"
  resource_group_name = azurerm_resource_group.resource_group.name
  sku                 = "Standard"
  depends_on = [
    azurerm_resource_group.resource_group,
  ]
}

resource "azurerm_firewall_policy" "firewall_policy" {
  location            = var.location
  name                = "${var.base_name}-firewall-policy"
  resource_group_name = azurerm_resource_group.resource_group.name
  depends_on = [
    azurerm_resource_group.resource_group,
  ]
}

resource "azurerm_firewall_policy_rule_collection_group" "firewall_policy_rule_collection_group" {
  firewall_policy_id = azurerm_firewall_policy.firewall_policy.id
  name               = "DefaultRuleCollectionGroup"
  priority           = 200

  dynamic "network_rule_collection" {
    for_each = length(var.dns_resolver_ips) == 0 ? [] : [1]
    content {
      action   = "Allow"
      name     = "ApprovedDNS"
      priority = 100
      rule {
        destination_addresses = var.dns_resolver_ips
        destination_ports     = ["53"]
        name                  = "ApprovedDNS"
        protocols             = ["TCP", "UDP"]
        source_addresses      = var.runner_subnet_address_prefixes
      }
    }
  }

  dynamic "network_rule_collection" {
    for_each = length(var.approved_private_service_rules) == 0 ? [] : [1]
    content {
      action   = "Allow"
      name     = "ApprovedPrivateServices"
      priority = 200
      dynamic "rule" {
        for_each = var.approved_private_service_rules
        content {
          name                  = rule.value.name
          source_addresses      = var.runner_subnet_address_prefixes
          destination_addresses = rule.value.destination_address_prefixes
          destination_ports     = rule.value.destination_port_ranges
          protocols             = rule.value.protocol == "*" ? ["Any"] : [upper(rule.value.protocol)]
        }
      }
    }
  }

  application_rule_collection {
    action   = "Allow"
    name     = "AllowApplicationRules"
    priority = 1000
    rule {
      name              = "GitHub"
      source_addresses  = var.runner_subnet_address_prefixes
      destination_fqdns = local.https_fqdns
      protocols {
        port = "443"
        type = "Https"
      }
    }
    # Sample rule for allowing access to a 3rd party service, the NPM registry at registry.npmjs.org
    # rule {
    #   name = "NPM"
    #   source_addresses = ["*"]
    #   destination_fqdns = ["registry.npmjs.org"]
    #   protocols {
    #     port = "443"
    #     type = "Https"
    #   }
    # }
  }
  depends_on = [
    azurerm_firewall_policy.firewall_policy,
  ]
}

resource "azurerm_firewall" "firewall" {
  location            = var.location
  name                = "${var.base_name}-firewall"
  resource_group_name = azurerm_resource_group.resource_group.name
  firewall_policy_id  = azurerm_firewall_policy.firewall_policy.id
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  ip_configuration {
    name                 = "ipConfig"
    public_ip_address_id = azurerm_public_ip.firewall_public_ip.id
    subnet_id            = azurerm_subnet.firewall_subnet.id
  }
  management_ip_configuration {
    name                 = "mgmtIpConfig"
    public_ip_address_id = azurerm_public_ip.firewall_management_public_ip.id
    subnet_id            = azurerm_subnet.management_subnet.id
  }
  depends_on = [
    azurerm_public_ip.firewall_public_ip,
    azurerm_public_ip.firewall_management_public_ip,
    azurerm_subnet.firewall_subnet,
    azurerm_firewall_policy.firewall_policy
  ]
}

resource "azurerm_route_table" "route_table" {
  location            = var.location
  name                = "${var.base_name}-rt"
  resource_group_name = azurerm_resource_group.resource_group.name
  depends_on = [
    azurerm_resource_group.resource_group
  ]
}

resource "azurerm_route" "firewall_route" {
  address_prefix         = "0.0.0.0/0"
  name                   = "${var.base_name}-firewall-route"
  next_hop_in_ip_address = azurerm_firewall.firewall.ip_configuration[0].private_ip_address
  next_hop_type          = "VirtualAppliance"
  resource_group_name    = azurerm_resource_group.resource_group.name
  route_table_name       = azurerm_route_table.route_table.name
  depends_on = [
    azurerm_firewall.firewall,
    azurerm_resource_group.resource_group,
    azurerm_route_table.route_table
  ]
}

resource "azurerm_subnet_route_table_association" "runner_subnet_route_table_association" {
  route_table_id = azurerm_route_table.route_table.id
  subnet_id      = azurerm_subnet.runner_subnet.id
  depends_on = [
    azurerm_route_table.route_table,
    azurerm_subnet.runner_subnet,
  ]
}

# There is no Terraform provider for GitHub.Network, so we have to use an ARM deployment template
# to create the GitHub.Network/networkSettings resource. See the note at the top of this documentation
# on deleting nested resources: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group_template_deployment

# WARNING: Attempting to delete the nested GitHub.Network/networkSettings resource will fail if the
# networkSettings is still in use in github.com. You need to delete resources in github.com before
# trying to delete the Azure resources.
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
