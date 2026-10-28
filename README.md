# github-runner-vnet

Terraform modules that configure and maintain the infrastructure needed to run GitHub-Hosted Action Runners in a [private network](https://docs.github.com/en/enterprise-cloud@latest/admin/configuration/configuring-private-networking-for-hosted-compute-products/configuring-private-networking-for-github-hosted-runners).

## Quick Start

1. Before running, review [pre-requisites](https://docs.github.com/en/enterprise-cloud@latest/admin/configuration/configuring-private-networking-for-hosted-compute-products/configuring-private-networking-for-github-hosted-runners#prerequisites) from the documentation to ensure your environment is properly configured.
1. The [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/) must be installed and on the system path, logged in with the identity that you want these resources created under, and Azure Subscription configured.
1. The `GitHub.Network` resource provider must be registered in the Azure Subscription. The Terraform modules contain HCL to register this provider, but it is commented out since you may not want this managed by Terraform. See the above GitHub documentation for a sample AZ CLI command to register the provider.

## Runner isolation and upgrade notes

Both network configurations now deny new inbound connections to the runner subnet and deny outbound access to runner-subnet, configured VNet and RFC1918 destinations unless narrowly allowed. These isolation controls are **on by default**. The firewall module associates the isolation NSG with the runner subnet only; the `0.0.0.0/0` route to the firewall is preserved. Both modules use concrete VNet/RFC1918 CIDRs rather than Azure's `VirtualNetwork` tag, because that tag can include a `0.0.0.0/0` UDR and block public GitHub traffic. Use `additional_private_address_prefixes` to deny other local or peered address space (for example non-RFC1918 peerings); approve specific destinations within it through `approved_private_service_rules`. Stateful responses to runner-initiated connections continue to work.

This is a breaking behavior change for consumers that rely on unsolicited inbound traffic or private destinations. Inventory required private services before upgrading and pass `approved_private_service_rules` with explicit destination CIDRs, port ranges, and protocols. Runner-subnet destinations are denied before these exceptions and cannot be reopened by them. No private-service exceptions are enabled by default. Configure existing filtering DNS resolvers with `dns_resolver_ips`, not private-service port-53 exceptions.

Rule priorities are 100 for inbound/runner-peer denies, 101-102 for approved TCP/UDP DNS, 103-104 for platform/other DNS denies, 110-189 for private services, 200 for configured VNet prefixes, 201 for RFC1918 networks and 202 for `additional_private_address_prefixes`. These are separate rules because Azure forbids overlapping prefixes within one rule; prefixes within `additional_private_address_prefixes` must not overlap each other. The NSG public HTTPS allow is 240 and Internet deny is 400. DNS denies precede private-service exceptions so those exceptions cannot reopen unauthorized port-53 access. Azure requires port `*` with the special `AzurePlatformDNS` tag; that DNS-specific tag is blocked, **not all traffic to 168.63.129.16**, which also provides other platform functions. The general unauthorized-DNS rule targets port 53 only.

## Egress profiles and DNS

The default is `egress_profile = "compatibility"`, so existing minimal module calls continue to plan. It preserves ordinary GitHub connectivity, **not exfiltration prevention**. The NSG module permits public TCP/443 instead of obsolete hardcoded GitHub IPs (which excluded current Actions endpoints); this is broader than the previous static list. The old Storage/all-ports allowance is removed, but public HTTPS still reaches unapproved storage accounts and DoH services. The firewall removes the Storage service-tag network bypass and uses runner-source-scoped HTTPS application rules, retaining documented shared GitHub/Blob dependencies. Shared endpoints can host attacker-controlled content.

`egress_profile = "restricted"` is an explicit opt-in. Plans fail until approved filtering resolvers and their owner/policy reference are supplied. NSG consumers supply `approved_public_egress_cidrs`; firewall consumers supply `approved_https_fqdns` (the complete list, without implicit shared-storage wildcards). `dns_policy_reference` identifies the **external filtering resolver owner and permitted-domain policy**. NSGs cannot enforce account ownership or DNS names, and IPs shared across accounts remain a residual risk. GitHub storage hostnames can rotate, so an exact-host list needs ongoing maintenance. Use the firewall with organization-controlled proxies/private endpoints when stronger guarantees are required.

With approved resolvers configured (in either profile), both modules set VNet DNS and permit UDP/TCP 53 only to them, denying platform DNS and other DNS destinations. Establish working filtered resolution before migration and recycle hosted runners to obtain the updated VNet settings. No resolver is provisioned. Without resolvers, Azure DNS is retained and DNS exfiltration is not mitigated. A policy reference is not proof of filtering: test a controlled forbidden domain and both direct-DNS transports. HTTPS/DoH exposure and permitted shared content remain outside port-53 controls.

An explicit working outbound path is also required. The NSG module does not provision paid NAT infrastructure; associate a consumer-managed NAT gateway or equivalent where Azure implicit outbound access is unavailable.

### Mitigation coverage

| Concern | Default (`compatibility`, no logging inputs) | Opt-in |
|---|---|---|
| Inbound and runner-peer isolation | Mitigated | — |
| Broad Storage service-tag access | NSG: Storage rule removed, but public 443 remains. Firewall: network bypass removed, `*.blob.core.windows.net` retained | `restricted` with explicit destinations |
| Azure platform DNS bypass | Not mitigated | `dns_resolver_ips` (+ `restricted`) |
| Shared-service FQDN content | Not mitigated | `restricted` with an explicit firewall FQDN list |
| Network diagnostics/flow logs | Not configured | `flow_logs`, firewall `diagnostics` |

## Diagnostics, versions and migration

Both modules accept `flow_logs` with existing regional Network Watcher/storage identifiers and retention days. This targets the **VNet**, not retired new-NSG-flow-log provisioning, and explicitly uses flow-log format version 2 instead of the provider's legacy version-1 default. Firewall consumers can additionally set `diagnostics` to an existing Log Analytics workspace and/or storage account for network, application and DNS-proxy categories. DNS-proxy records require actual proxy traffic; this module directs clients to the supplied external resolvers instead of silently enabling a forwarding proxy and calling it filtering.

Logging is opt-in to avoid duplicating externally managed resources/costs. Flow-log resources are created in the supplied Network Watcher resource group, not the module resource group; remove them with Terraform rather than relying on resource-group deletion. Verify destination access, regional eligibility, storage network rules, retention ownership, delegated-runner capture support and ingestion before deployment. An enabled resource is not proof of traffic coverage. VNet flow logs are needed for local traffic that bypasses the firewall. Log Analytics ingestion and flow-log storage/processing incur additional charges.

AzureRM **>= 4.11.0, < 6.0** is now required (previously `>3.0.0`). 4.11.0 is the first release whose `azurerm_network_watcher_flow_log` supports VNet `target_resource_id`; validation and `terraform test` pass on 4.11.0, 4.81.0 and 5.11.0 with AzAPI 1.14.0 and Terraform 1.11.2, and fail on 4.10.0. Consumers on AzureRM 3.x or 4.0-4.10 must upgrade the provider first. Original resource addresses, firewall Standard SKU and public-IP architecture are retained.

Neither profile makes secrets safe for untrusted workflows. Keep untrusted workloads and secrets in separate trust boundaries. Static validation is not proof of deployed isolation: verify effective rules and actual runner connectivity in your environment.

Example input:

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

This repo contains two Terraform modules:

- [nsg](./modules/nsg/) module: Uses a [Network Security Group (NSG)](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview) to manage the network security of the VNet.

```hcl
module "github_runner_vnet" {
  # Use the nsg version
  source = "github.com/github/terraform-github-runner-vnet/nsg"

  # The resources use this base_name as a name prefix, e.g. ${base_name}-rg for the resource group
  base_name = "vnet-test"

  # Retrieve through the GitHub API (see GitHub docs for instructions)
  github_business_id = "12345"

  # Default compatibility egress: public HTTPS/shared-service risks remain.
  # Set egress_profile = "restricted" with resolvers and destinations to opt in.
}
```

- [firewall](./modules/firewall/) module: Uses an [Azure Firewall](https://learn.microsoft.com/en-us/azure/firewall/overview) to manage the network security of the VNet.

<details><summary>Terraform config for the firewall</summary>

Provision and configure the infrastructure in Terraform by calling this module:

```hcl
module "github_runner_vnet" {
  # Use the firewall version
  source = "github.com/github/terraform-github-runner-vnet/firewall"

  # The resources use this base_name as a name prefix, e.g. ${base_name}-rg for the resource group
  base_name = "vnet-test"

  # Retrieve through the GitHub API (see GitHub docs for instructions)
  github_business_id = "12345"

  # Default compatibility egress: shared GitHub/Blob egress risks remain.
  # Set egress_profile = "restricted" with resolvers and destinations to opt in.
}
```

</details>

The output of these modules is the Resource ID for the `GitHub.Network/networkSettings` resource. Paste this ID into the github.com UI for configuring the Azure Virtual Network.

![GitHub UI](./images/github-az-network-settings.jpg)

## License

This project is licensed under the terms of the MIT open source license. Please refer to [MIT](./LICENSE) for the full terms.

## Maintainers

Please refer to [CODEOWNERS](./CODEOWNERS) for a list of maintainers.
