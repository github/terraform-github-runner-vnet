module "vnet" {
  source = "../../../modules/nsg"

  base_name                    = "runner-isolation-fixture"
  github_business_id           = "123456"
  egress_profile               = "restricted"
  dns_resolver_ips             = ["10.20.1.4"]
  dns_policy_reference         = "fixture/filtered-dns"
  approved_public_egress_cidrs = ["192.0.2.10/32"]
  approved_private_service_rules = [
    {
      name                         = "private-api"
      destination_address_prefixes = ["10.20.1.15/32"]
      destination_port_ranges      = ["443"]
      protocol                     = "Tcp"
    }
  ]
}
