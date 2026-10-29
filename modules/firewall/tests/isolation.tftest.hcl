mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/virtualNetworks/runners"
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg"
    }
  }

  mock_resource "azurerm_firewall_policy" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/firewallPolicies/runner-isolation-test-firewall-policy"
    }
  }

  mock_resource "azurerm_public_ip" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/publicIPAddresses/runner-isolation-test-firewall-ip"
    }
  }

  mock_resource "azurerm_route_table" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/routeTables/runner-isolation-test-rt"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/virtualNetworks/runner-isolation-test-vnet/subnets/runner-isolation-test-runner-subnet"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/networkSecurityGroups/runner-isolation-test-runner-nsg"
    }
  }
}

mock_provider "azapi" {
  override_during = plan

  mock_resource "azapi_resource" {
    defaults = {
      output = "{\"tags\":{\"GitHubId\":\"mock-network-settings-id\"}}"
    }
  }
}

override_resource {
  target = azurerm_subnet.firewall_subnet
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/virtualNetworks/runner-isolation-test-vnet/subnets/AzureFirewallSubnet"
  }
}

override_resource {
  target = azurerm_subnet.management_subnet
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/runner-isolation-test-rg/providers/Microsoft.Network/virtualNetworks/runner-isolation-test-vnet/subnets/AzureFirewallManagementSubnet"
  }
}
run "isolates_runner_subnet" {
  command = plan

  variables {
    base_name          = "runner-isolation-test"
    github_business_id = "123456"
    egress_profile     = "compatibility"
    approved_private_service_rules = [
      {
        name                         = "private-api"
        destination_address_prefixes = ["10.20.1.15/32"]
        destination_port_ranges      = ["443"]
        protocol                     = "Tcp"
      }
    ]
  }

  assert {
    condition = (
      azurerm_subnet_network_security_group_association.runner_subnet_nsg_association.subnet_id == azurerm_subnet.runner_subnet.id &&
      azurerm_subnet_network_security_group_association.runner_subnet_nsg_association.network_security_group_id == azurerm_network_security_group.runner_nsg.id
    )
    error_message = "The runner NSG must be associated with the runner subnet."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.runner_nsg.security_rule :
      rule.name == "DenyInboundRunnerTraffic" &&
      rule.direction == "Inbound" &&
      rule.access == "Deny" &&
      rule.priority == 100 &&
      rule.source_address_prefix == "*" &&
      rule.destination_address_prefix == "*"
    ])
    error_message = "The runner NSG must deny all new inbound runner traffic."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.runner_nsg.security_rule :
      rule.name == "DenyRunnerPeerOutbound" &&
      rule.access == "Deny" &&
      rule.priority < 110 &&
      try(contains(rule.destination_address_prefixes, "10.0.0.0/24"), false)
    ])
    error_message = "Runner-subnet destinations must be denied before private-service exceptions."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.runner_nsg.security_rule :
      rule.name == "AllowPrivateService-private-api" &&
      rule.access == "Allow" &&
      rule.priority == 110 &&
      try(contains(rule.destination_address_prefixes, "10.20.1.15/32"), false)
    ])
    error_message = "The explicitly approved private service must be allowed before the VNet deny."
  }

  assert {
    condition = alltrue([
      for rule in azurerm_network_security_group.runner_nsg.security_rule :
      !(
        rule.direction == "Outbound" &&
        rule.access == "Allow" &&
        try(rule.destination_address_prefix == "VirtualNetwork", false)
      )
    ])
    error_message = "The runner NSG must not allow broad outbound VirtualNetwork access."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.runner_nsg.security_rule :
      rule.name == "DenyVirtualNetworkOutbound" &&
      rule.direction == "Outbound" &&
      rule.access == "Deny" &&
      rule.priority == 200 &&
      try(contains(rule.destination_address_prefixes, "10.0.0.0/16"), false)
      ]) && anytrue([
      for rule in azurerm_network_security_group.runner_nsg.security_rule :
      rule.name == "DenyOtherPrivateNetworks" &&
      rule.direction == "Outbound" &&
      rule.access == "Deny" &&
      rule.priority == 201 &&
      try(contains(rule.destination_address_prefixes, "10.0.0.0/8"), false) &&
      try(contains(rule.destination_address_prefixes, "172.16.0.0/12"), false) &&
      try(contains(rule.destination_address_prefixes, "192.168.0.0/16"), false)
    ])
    error_message = "Configured VNet and RFC1918 destinations must be denied without a UDR-expanded VirtualNetwork tag."
  }

  assert {
    condition = (
      azurerm_route.firewall_route.address_prefix == "0.0.0.0/0" &&
      azurerm_route.firewall_route.next_hop_type == "VirtualAppliance" &&
      azurerm_subnet_route_table_association.runner_subnet_route_table_association.subnet_id == azurerm_subnet.runner_subnet.id
    )
    error_message = "The runner subnet's default route to the firewall must remain intact."
  }

  assert {
    condition = alltrue(flatten([
      for collection in azurerm_firewall_policy_rule_collection_group.firewall_policy_rule_collection_group.application_rule_collection :
      [for rule in collection.rule : tolist(rule.destination_fqdns) == tolist([
        "github.com",
        "api.github.com",
        "*.actions.githubusercontent.com",
        "codeload.github.com",
        "*.blob.core.windows.net",
        "objects.githubusercontent.com",
        "objects-origin.githubusercontent.com",
        "github-releases.githubusercontent.com",
        "github-registry-files.githubusercontent.com",
        "*.pkg.github.com",
        "pkg-containers.githubusercontent.com",
        "ghcr.io",
        "github-cloud.githubusercontent.com",
        "github-cloud.s3.amazonaws.com",
        "dependabot-actions.githubapp.com",
        "release-assets.githubusercontent.com",
        "api.snapcraft.io",
        "*.core.windows.net",
        "cafe.github.com",
        "*.ghcr.io",
        "*.githubassets.com",
        "*.github.com",
        "*.githubusercontent.com"
      ])]
    ]))
    error_message = "Compatibility must preserve its existing ordered HTTPS destination list."
  }
}

run "rejects_unbounded_private_destinations" {
  command = plan

  variables {
    base_name          = "runner-isolation-test"
    github_business_id = "123456"
    egress_profile     = "compatibility"
    approved_private_service_rules = [
      {
        name                         = "unbounded"
        destination_address_prefixes = ["0.0.0.0/0"]
        destination_port_ranges      = ["443"]
        protocol                     = "Tcp"
      }
    ]
  }

  expect_failures = [var.approved_private_service_rules]
}

run "restricted_dns_storage_and_logging" {
  command = plan
  variables {
    base_name            = "runner-isolation-test"
    github_business_id   = "123456"
    egress_profile       = "restricted"
    dns_resolver_ips     = ["10.20.1.4"]
    dns_policy_reference = "network-team/filtered-domains"
    approved_https_fqdns = ["github.com", "approved.blob.core.windows.net"]
    diagnostics = {
      log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/logs/providers/Microsoft.OperationalInsights/workspaces/firewall"
    }
    flow_logs = {
      network_watcher_name                = "existing-watcher"
      network_watcher_resource_group_name = "existing-watcher-rg"
      storage_account_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/logs/providers/Microsoft.Storage/storageAccounts/flowlogs"
      retention_days                      = 7
    }
  }
  assert {
    condition = (
      alltrue([for collection in azurerm_firewall_policy_rule_collection_group.firewall_policy_rule_collection_group.network_rule_collection :
        collection.name != "AllowAzureStorage"
      ]) &&
      alltrue(flatten([for collection in azurerm_firewall_policy_rule_collection_group.firewall_policy_rule_collection_group.application_rule_collection :
        [for rule in collection.rule :
          toset(rule.source_addresses) == toset(["10.0.0.0/24"]) &&
          toset(rule.destination_fqdns) == toset(["github.com", "approved.blob.core.windows.net"])
        ]
      ])) &&
      anytrue([for rule in azurerm_network_security_group.runner_nsg.security_rule :
        rule.name == "DenyDNS-platform" && rule.access == "Deny" &&
        rule.destination_address_prefix == "AzurePlatformDNS" && rule.destination_port_range == "*" &&
        rule.priority == 103
      ]) &&
      anytrue([for rule in azurerm_network_security_group.runner_nsg.security_rule :
        rule.name == "DenyDNS-other" && rule.access == "Deny" &&
        rule.destination_address_prefix == "*" && rule.destination_port_range == "53" &&
        rule.priority == 104
      ]) &&
      length(azurerm_monitor_diagnostic_setting.firewall) == 1 &&
      length(azurerm_monitor_diagnostic_setting.firewall[0].enabled_log) == 3 &&
      azurerm_network_watcher_flow_log.runners[0].version == 2 &&
      azurerm_network_watcher_flow_log.runners[0].target_resource_id == azurerm_virtual_network.vnet.id
    )
    error_message = "Restricted firewall must omit Storage bypass/shared wildcards, restrict sources, enforce DNS and configure supported logging."
  }
}

run "historical_minimal_call_plans_with_compatibility" {
  command = plan
  variables {
    base_name          = "runner-isolation-test"
    github_business_id = "123456"
  }
  assert {
    condition     = output.network_settings_id == "mock-network-settings-id"
    error_message = "The GitHub network settings ID must decode from the AzAPI response."
  }

  assert {
    condition = anytrue([for rule in azurerm_network_security_group.runner_nsg.security_rule :
      rule.name == "DenyInboundRunnerTraffic"
      ]) && alltrue([for rule in azurerm_network_security_group.runner_nsg.security_rule :
      !startswith(rule.name, "DenyDNS-")
      ]) && alltrue(flatten([for collection in azurerm_firewall_policy_rule_collection_group.firewall_policy_rule_collection_group.application_rule_collection :
        [for rule in collection.rule : contains(rule.destination_fqdns, "github.com")]
    ]))
    error_message = "A minimal call must plan with isolation and compatibility egress, without implicit DNS changes."
  }
}

run "restricted_requires_resolvers_and_destinations" {
  command = plan
  variables {
    base_name          = "runner-isolation-test"
    github_business_id = "123456"
    egress_profile     = "restricted"
  }
  expect_failures = [azurerm_network_security_group.runner_nsg]
}

run "denies_additional_peered_prefixes" {
  command = plan
  variables {
    base_name                           = "runner-isolation-test"
    github_business_id                  = "123456"
    additional_private_address_prefixes = ["100.64.0.0/16"]
  }
  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.runner_nsg.security_rule :
      rule.name == "DenyAdditionalPrivateNetworks" &&
      rule.access == "Deny" &&
      rule.priority == 202 &&
      tolist(rule.destination_address_prefixes) == tolist(["100.64.0.0/16"])
    ])
    error_message = "Additional local or peered prefixes must be denied after private-service exceptions."
  }
}

run "rejects_overlapping_additional_prefixes" {
  command = plan
  variables {
    base_name                           = "runner-isolation-test"
    github_business_id                  = "123456"
    additional_private_address_prefixes = ["100.64.0.0/10", "100.64.1.0/24"]
  }
  expect_failures = [var.additional_private_address_prefixes]
}

run "rejects_overlapping_private_service_destinations" {
  command = plan
  variables {
    base_name          = "runner-isolation-test"
    github_business_id = "123456"
    approved_private_service_rules = [
      {
        name                         = "overlap"
        destination_address_prefixes = ["10.20.0.0/16", "10.20.1.15/32"]
        destination_port_ranges      = ["443"]
        protocol                     = "Tcp"
      }
    ]
  }
  expect_failures = [var.approved_private_service_rules]
}

run "accepts_adjacent_nonoverlapping_prefixes" {
  command = plan
  variables {
    base_name                           = "runner-isolation-test"
    github_business_id                  = "123456"
    additional_private_address_prefixes = ["100.64.0.0/24", "100.64.1.0/24", "198.18.0.0/15"]
    approved_private_service_rules = [
      {
        name                         = "adjacent"
        destination_address_prefixes = ["10.20.1.0/25", "10.20.1.128/25"]
        destination_port_ranges      = ["443"]
        protocol                     = "Tcp"
      }
    ]
  }
  assert {
    condition     = length(var.additional_private_address_prefixes) == 3
    error_message = "Adjacent, non-overlapping prefixes must be accepted."
  }
}

run "rejects_non_adjacent_and_duplicate_overlaps" {
  command = plan
  variables {
    base_name                           = "runner-isolation-test"
    github_business_id                  = "123456"
    additional_private_address_prefixes = ["100.64.0.0/10", "198.18.0.0/15", "100.65.0.0/16"]
    approved_private_service_rules = [
      {
        name                         = "duplicate"
        destination_address_prefixes = ["10.20.1.15/32", "10.30.0.0/16", "10.20.1.15/32"]
        destination_port_ranges      = ["443"]
        protocol                     = "Tcp"
      }
    ]
  }
  expect_failures = [var.additional_private_address_prefixes, var.approved_private_service_rules]
}

run "rejects_ipv6_private_prefixes" {
  command = plan
  variables {
    base_name                           = "runner-isolation-test"
    github_business_id                  = "123456"
    additional_private_address_prefixes = ["fd00::/8"]
  }
  expect_failures = [var.additional_private_address_prefixes]
}
