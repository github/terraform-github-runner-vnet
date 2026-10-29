mock_provider "azurerm" {}
mock_provider "azapi" {
  override_during = plan

  mock_resource "azapi_resource" {
    defaults = {
      output = "{\"tags\":{\"GitHubId\":\"mock-network-settings-id\"}}"
    }
  }
}

variables {
  egress_profile = "compatibility"
}

run "isolates_runner_network" {
  command = plan

  variables {
    base_name          = "runner-isolation-test"
    github_business_id = "123456"
    runner_subnet_address_prefixes = [
      "10.0.0.0/24"
    ]
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
    condition = anytrue([
      for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "DenyInboundRunnerTraffic" &&
      rule.direction == "Inbound" &&
      rule.access == "Deny" &&
      rule.priority == 100 &&
      rule.source_address_prefix == "*" &&
      rule.destination_address_prefix == "*"
    ])
    error_message = "The NSG must deny all new inbound runner traffic."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "DenyRunnerPeerOutbound" &&
      rule.direction == "Outbound" &&
      rule.access == "Deny" &&
      rule.priority < 110 &&
      try(contains(rule.destination_address_prefixes, "10.0.0.0/24"), false)
    ])
    error_message = "Runner-subnet destinations must be denied before private-service exceptions."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "AllowPrivateService-private-api" &&
      rule.access == "Allow" &&
      rule.priority == 110 &&
      try(contains(rule.destination_address_prefixes, "10.20.1.15/32"), false)
    ])
    error_message = "The explicitly approved private service must be allowed before the VNet deny."
  }

  assert {
    condition = alltrue([
      for rule in azurerm_network_security_group.actions_nsg.security_rule :
      !(
        rule.direction == "Outbound" &&
        rule.access == "Allow" &&
        try(rule.destination_address_prefix == "VirtualNetwork", false)
      )
    ])
    error_message = "The NSG must not allow broad outbound VirtualNetwork access."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "DenyVirtualNetworkOutbound" &&
      rule.direction == "Outbound" &&
      rule.access == "Deny" &&
      rule.priority == 200 &&
      try(contains(rule.destination_address_prefixes, "10.0.0.0/16"), false)
      ]) && anytrue([
      for rule in azurerm_network_security_group.actions_nsg.security_rule :
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
}

run "rejects_unbounded_private_destinations" {
  command = plan

  variables {
    base_name          = "runner-isolation-test"
    github_business_id = "123456"
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

run "denies_additional_peered_prefixes" {
  command = plan

  variables {
    base_name                           = "runner-isolation-test"
    github_business_id                  = "123456"
    additional_private_address_prefixes = ["100.64.0.0/16"]
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.actions_nsg.security_rule :
      rule.name == "DenyAdditionalPrivateNetworks" &&
      rule.access == "Deny" &&
      rule.priority == 202 &&
      tolist(rule.destination_address_prefixes) == tolist(["100.64.0.0/16"])
    ])
    error_message = "Additional local or peered prefixes must be denied after private-service exceptions."
  }
}

run "rejects_unbounded_additional_prefixes" {
  command = plan

  variables {
    base_name                           = "runner-isolation-test"
    github_business_id                  = "123456"
    additional_private_address_prefixes = ["0.0.0.0/0"]
  }

  expect_failures = [var.additional_private_address_prefixes]
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
