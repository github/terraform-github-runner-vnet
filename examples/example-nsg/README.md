# Network Security Group Example

This folder shows an example of Terraform code that uses the [nsg](../../modules/nsg) module to create an Azure VNET using Network Security Groups to manage network access.

## Source reproducibility

The module `source` is pinned to a full commit SHA, currently the latest
published commit (`36d428cec62e4e9d3b91c176cdb8da62d35e883f`), so that `terraform init`
always fetches the same code. Update the `ref` to a commit or release you have
reviewed when upgrading. `tests/fixtures/nsg` exercises the module from the
local checkout.
