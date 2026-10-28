module "vnet" {
  source = "../../../modules/firewall"

  base_name            = "runner-isolation-fixture"
  github_business_id   = "123456"
  egress_profile       = "restricted"
  dns_resolver_ips     = ["10.20.1.4"]
  dns_policy_reference = "fixture/filtered-dns"
  approved_https_fqdns = ["github.com", "approved.blob.core.windows.net"]
  diagnostics = {
    storage_account_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/logs/providers/Microsoft.Storage/storageAccounts/flowlogs"
  }
  approved_private_service_rules = [
    {
      name                         = "private-api"
      destination_address_prefixes = ["10.20.1.15/32"]
      destination_port_ranges      = ["443"]
      protocol                     = "Tcp"
    }
  ]
}
