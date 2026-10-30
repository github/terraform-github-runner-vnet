# VNet with Network Security Groups

This folder contains a Terraform module to create an Azure Virtual Network that uses Network Security Groups (NSGs) to control network access. The NSG configuration is simpler than the Azure Firewall method and there is no added cost. However using NSGs requires you to use IP addresses in the access rules for external services, which makes managing the access rules more complex and potentially prone to failures due to IP/DNS changes.

The runner subnet NSG denies all new inbound connections and blocks outbound connections to runner-subnet, configured VNet, RFC1918 and any `additional_private_address_prefixes` destinations using concrete CIDRs (not the `VirtualNetwork` tag, which can include a `0.0.0.0/0` UDR). The default compatibility profile permits public TCP/443, replacing obsolete GitHub IP lists and the all-protocol Storage allowance. This restores dynamic GitHub connectivity but deliberately **does not prevent HTTPS exfiltration, DoH or access to unapproved storage accounts**. Supply your own working outbound path (for example an existing NAT gateway); this module does not create one. GitHub-hosted runners on Azure private networking are IPv4-only, so the VNet and subnet address inputs accept IPv4 CIDRs only. Control any IPv6 address space or peerings outside this module. If runners need a private service, pass only its CIDR, required ports, and protocol:

```hcl
approved_private_service_rules = [
  {
    name                         = "internal-api"
    destination_address_prefixes = ["10.20.1.15/32"]
    destination_port_ranges      = ["443"]
    protocol                     = "Tcp"
  }
]
```

Rules use priorities 100 for inbound/runner-peer denies, 101-102 for approved TCP/UDP DNS, 103-104 for platform/other DNS denies, 110-189 for approved private destinations, 200-202 for VNet/RFC1918/additional-prefix denies, 240 for public HTTPS, and 400 for the Internet deny. Private-service exceptions cannot reopen runner-peer connections or unauthorized DNS.

The default is no private-service exceptions. Before upgrading, inventory private dependencies. Configure filtering resolver IPs through `dns_resolver_ips`; these set VNet DNS and explicitly block direct Azure platform/other DNS on port 53 without blocking other platform services. If no resolver is configured, compatibility mode retains Azure DNS and DNS-exfiltration protection is not provided.

Opt-in restricted mode requires approved resolver IPs plus their external owner/policy reference in `dns_policy_reference`, and permits only `approved_public_egress_cidrs` over HTTPS. No static GitHub list is maintained here. An empty public list permits no public HTTPS. The caller must maintain current GitHub/proxy destinations, validate resolver filtering and account for shared-IP ownership/DoH risks. Prefer the firewall/proxy approach for account/domain-sensitive policy.

### Maintaining a restricted IP allowlist

NSG restricted mode requires ongoing allowlist maintenance. The module does not ship or fetch GitHub IP ranges. Sources:

- The [GitHub meta API](https://api.github.com/meta) ([REST documentation](https://docs.github.com/en/rest/meta/meta#get-github-meta-information)): the `actions`, `api`, `web`, `git` and `packages` keys.
- [About GitHub's IP addresses](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-githubs-ip-addresses).
- [Communication requirements for GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#communication-requirements-for-github-hosted-runners) for the domains runners need, including storage and any package registries you use.

The full set is impractical to embed. On 2026-10-28 the `actions` key alone listed 5,553 IPv4 ranges, and those five keys together listed 5,707. Azure allows [6,000 source or destination address prefixes per NSG](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#networking-limits), so this leaves little headroom and can exceed the limit as the list grows. The `actions` ranges are also largely shared Azure address space, so an allowlist built from them offers limited exfiltration protection. Subset the list to the services you need, re-check it on a schedule and test runner startup after each update. If that is not acceptable, use the firewall module.

Optional `flow_logs` targets the VNet using existing regional Network Watcher/storage resources; `virtual_network_id` and `runner_network_security_group_id` support externally managed logging. Avoid duplicate flow logs and validate actual delegated-runner coverage. See the [root migration and residual-risk guidance](../../README.md) for provider requirements, costs and guarantees.

See the [related example](../../examples/example-nsg/) for how to use this module.
