# VNet with Firewall

This folder contains a Terraform module to create an Azure Virtual Network that uses an Azure Firewall to control network access. The firewall configuration is a bit more complex than the Network Security Group method and there is an associated charge with the Azure Firewall product. However using Azure Firewall instead of NSGs allows you to use host names instead of IP addresses in the access rules, which makes managing the access rules easier and less prone to IP/DNS changes affecting your network access.

The module also associates a dedicated NSG with the runner subnet only. It denies all new inbound connections and blocks outbound runner peers, configured VNet prefixes and RFC1918 destinations, because local routes do not necessarily traverse the firewall. It uses concrete CIDRs: Azure's `VirtualNetwork` service tag can include the firewall's `0.0.0.0/0` UDR and inadvertently deny public GitHub traffic. The firewall and management subnets are not associated with this NSG. Runner-initiated public GitHub traffic continues to use the existing default route to the firewall. Use `additional_private_address_prefixes` to deny other local or peered address space, such as non-RFC1918 peerings; custom routes still need an independent review.

Private-service access is denied by default. To allow a required private destination, configure `approved_private_service_rules` with its CIDR, required ports, and protocol. Runner-subnet destinations remain denied even if included in an exception:

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

NSG priorities are 100 for inbound/runner-peer denies, 101-102 for approved DNS, 103-104 for platform/other DNS denies, 110-189 for private services, 200 for configured VNet prefixes, 201 for other RFC1918 networks and 202 for additional prefixes. Configure filtering resolvers through `dns_resolver_ips`; VNet DNS uses those addresses and port-53 bypasses are denied before private-service rules. The module does not provision a filtering resolver or treat a forwarding proxy as filtering.

This inbound behavior is a breaking change for consumers that rely on unsolicited inbound traffic. Inventory private dependencies before upgrading and test the updated policy with a dedicated runner group. Stateful responses to runner-initiated connections are allowed.

The broad Storage network-rule bypass is removed in **both** profiles; application rules now govern Blob access. All module-managed rule sources are runner-subnet prefixes, not `*`. Approved private-service network rules mirror the explicit NSG exceptions for routed traffic.

The default `egress_profile = "compatibility"` allows documented GitHub dependencies, including shared Blob storage and package endpoints. It is not account-level exfiltration prevention. `approved_https_fqdns` adds optional destinations in compatibility mode. Opt-in `restricted` mode fails planning without explicit HTTPS destinations, filtering resolvers and their owner/policy reference; in restricted mode this input is the complete HTTPS list: no Storage bypass or implicit shared Blob wildcard is added. Supply current organization-approved GitHub, artifact/cache and configured package destinations; test them rather than removing required endpoints blindly. Shared content and explicitly approved wildcards remain risks.

GitHub artifact/cache storage hosts can rotate. An exact-host list learned during one test is not a stable production dependency list, even if that test succeeds. Revalidate cold starts, runner updates and supported workloads when maintaining restricted destinations; use organization-controlled proxies or private endpoints when a maintained shared-service allowlist cannot meet the required guarantee.

Restricted mode also requires `dns_resolver_ips` and `dns_policy_reference` identifying the external filtering resolver owner/policy. Without resolvers, the module continues to use Azure DNS and does not mitigate DNS exfiltration. Test forbidden names, direct UDP/TCP platform/other DNS and DoH exposure separately.

Set `diagnostics` to an existing workspace/storage destination for firewall network, application and DNS-proxy categories. DNS-proxy records require actual proxy traffic; runner DNS goes directly to the configured resolvers. Set `flow_logs` for VNet flow capture, including local paths that bypass the firewall. Both are opt-in to avoid duplicate externally managed logging and incur destination/ingestion charges. Validate regional/storage access and actual delegated-runner coverage. Resource IDs are exported for external diagnostics.

See [root migration guidance](../../README.md) for AzureRM provider requirements, priority changes, compatibility risks and acceptance criteria.

See the [related example](../../examples/example-firewall/) for how to use this module.
