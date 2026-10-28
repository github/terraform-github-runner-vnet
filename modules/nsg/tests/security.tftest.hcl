mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/logs/providers/Microsoft.Network/virtualNetworks/runners"
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

variables {
  base_name          = "runner-security-test"
  github_business_id = "123456"
}

run "compatibility_is_https_only" {
  command = plan
  variables {
    egress_profile = "compatibility"
  }
  assert {
    condition = (
      length([for rule in azurerm_network_security_group.actions_nsg.security_rule :
        rule if rule.access == "Allow" && rule.destination_address_prefix == "Storage"
      ]) == 0 &&
      anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
        rule.name == "AllowPublicHTTPSCompatibility" && rule.protocol == "Tcp" &&
        rule.destination_port_range == "443" && rule.priority > 200
      ])
    )
    error_message = "Compatibility must use only public TCP/443 after private-network denies, not broad Storage access."
  }
}

run "restricted_controls_dns_and_destinations" {
  command = plan
  variables {
    egress_profile               = "restricted"
    dns_resolver_ips             = ["10.1.0.4"]
    dns_policy_reference         = "network-team/approved-domain-policy"
    approved_public_egress_cidrs = ["192.0.2.10/32"]
  }
  assert {
    condition = (
      azurerm_virtual_network.vnet.dns_servers == tolist(["10.1.0.4"]) &&
      alltrue([for name in ["AllowApprovedDNS-tcp", "AllowApprovedDNS-udp", "DenyDNS-platform", "DenyDNS-other"] :
        anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule : rule.name == name])
      ]) &&
      anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
        rule.name == "DenyDNS-platform" && rule.destination_address_prefix == "AzurePlatformDNS" &&
        rule.destination_port_range == "*" && rule.access == "Deny" && rule.priority == 103
      ]) &&
      anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
        rule.name == "DenyDNS-other" && rule.destination_address_prefix == "*" &&
        rule.destination_port_range == "53" && rule.access == "Deny" && rule.priority == 104
      ]) &&
      alltrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
        rule.name != "AllowPublicHTTPSCompatibility"
      ]) &&
      anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
        rule.name == "AllowApprovedPublicHTTPS" && try(contains(rule.destination_address_prefixes, "192.0.2.10/32"), false)
      ])
    )
    error_message = "Restricted policy must configure approved DNS, block bypass and omit unrestricted HTTPS."
  }
}

run "historical_minimal_call_plans_with_compatibility" {
  command = plan
  assert {
    condition     = output.network_settings_id == "mock-network-settings-id"
    error_message = "The GitHub network settings ID must decode from the AzAPI response."
  }

  assert {
    condition = anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "AllowPublicHTTPSCompatibility"
      ]) && anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "DenyInboundRunnerTraffic"
      ]) && alltrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
      !startswith(rule.name, "DenyDNS-")
    ]) && length(azurerm_virtual_network.vnet.dns_servers) == 0
    error_message = "A minimal call must plan with isolation and compatibility egress, without implicit DNS changes."
  }
}

run "restricted_requires_filtering_resolver" {
  command = plan
  variables {
    egress_profile = "restricted"
  }
  expect_failures = [azurerm_network_security_group.actions_nsg]
}

run "rejects_platform_resolver" {
  command = plan
  variables {
    egress_profile   = "compatibility"
    dns_resolver_ips = ["168.63.129.16"]
  }
  expect_failures = [var.dns_resolver_ips]
}

run "rejects_noncanonical_default_route" {
  command = plan
  variables {
    egress_profile               = "compatibility"
    approved_public_egress_cidrs = ["0.0.0.1/0"]
  }
  expect_failures = [var.approved_public_egress_cidrs]
}

run "vnet_flow_logging" {
  command = plan
  variables {
    egress_profile = "compatibility"
    flow_logs = {
      network_watcher_name                = "existing-watcher"
      network_watcher_resource_group_name = "existing-watcher-rg"
      storage_account_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/logs/providers/Microsoft.Storage/storageAccounts/flowlogs"
      retention_days                      = 7
    }
  }
  assert {
    condition = (
      length(azurerm_network_watcher_flow_log.runners) == 1 &&
      azurerm_network_watcher_flow_log.runners[0].version == 2 &&
      azurerm_network_watcher_flow_log.runners[0].target_resource_id == azurerm_virtual_network.vnet.id &&
      azurerm_network_watcher_flow_log.runners[0].retention_policy[0].days == 7
    )
    error_message = "Logging must target the VNet, not the deprecated NSG flow-log capture point."
  }
}

run "rejects_overlapping_public_cidrs" {
  command = plan
  variables {
    egress_profile               = "restricted"
    dns_resolver_ips             = ["10.1.0.4"]
    dns_policy_reference         = "network-team/approved-domain-policy"
    approved_public_egress_cidrs = ["192.0.2.0/24", "192.0.2.10/32"]
  }
  expect_failures = [var.approved_public_egress_cidrs]
}

run "accepts_adjacent_public_cidrs" {
  command = plan
  variables {
    egress_profile               = "restricted"
    dns_resolver_ips             = ["10.1.0.4"]
    dns_policy_reference         = "network-team/approved-domain-policy"
    approved_public_egress_cidrs = ["192.0.2.0/25", "192.0.2.128/25"]
  }
  assert {
    condition = anytrue([for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "AllowApprovedPublicHTTPS" && length(coalesce(rule.destination_address_prefixes, [])) == 2
    ])
    error_message = "Adjacent, non-overlapping public CIDRs must be accepted."
  }
}
