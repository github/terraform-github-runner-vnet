# Create a VNET using an Azure Network Security Group to control the VNET network access
module "vnet" {
  source             = "git::https://github.com/github/terraform-github-runner-vnet.git//modules/nsg?ref=36d428cec62e4e9d3b91c176cdb8da62d35e883f"
  base_name          = var.base_name
  github_business_id = var.github_business_id
}
