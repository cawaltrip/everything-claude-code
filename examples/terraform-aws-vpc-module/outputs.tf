output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, keyed by AZ"
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, keyed by AZ"
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway, or empty string when disabled"
  value       = try(aws_nat_gateway.this[0].id, "")
}

output "public_route_table_id" {
  description = "ID of the public route table"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID of the private route table, or empty string when NAT disabled"
  value       = try(aws_route_table.private[0].id, "")
}

output "default_security_group_id" {
  description = "ID of the locked-down default security group"
  value       = aws_default_security_group.this.id
}
