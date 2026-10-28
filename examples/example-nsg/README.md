# Network Security Group Example

This folder shows an example of Terraform code that uses the [nsg](../../modules/nsg) module to create an Azure VNET using Network Security Groups to manage network access.

## Using this module from another repository

This example references the module by relative path so it always matches the
code in this repository. When consuming the module from your own configuration,
pin the source to a release tag or full commit SHA you have reviewed:

```hcl
module "vnet" {
  source             = "git::https://github.com/github/terraform-github-runner-vnet.git//modules/nsg?ref=<release-tag-or-full-commit-sha>"
  base_name          = var.base_name
  github_business_id = var.github_business_id
}
```
