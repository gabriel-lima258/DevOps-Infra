locals {
  internet_cidr_block = "0.0.0.0/0"

  subnet_pub_config = merge([
    for group_name, subnets in var.subnet_pub_config : {
      for subnet_key, subnet in subnets : subnet_key => merge(subnet, { group = group_name })
    }
  ]...)

  subnet_pvt_config = merge([
    for group_name, subnets in var.subnet_pvt_config : {
      for subnet_key, subnet in subnets : subnet_key => merge(subnet, { group = group_name })
    }
  ]...)
}