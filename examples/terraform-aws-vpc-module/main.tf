locals {
  module_tags = merge(
    var.tags,
    {
      Module    = "terraform-aws-vpc-module"
      ManagedBy = "terraform"
    }
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = merge(local.module_tags, {
    Name        = var.name
    Environment = var.environment
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name        = "${var.name}-igw"
    Environment = var.environment
  })
}

resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(local.module_tags, {
    Name        = "${var.name}-public-${each.key}"
    Environment = var.environment
    Tier        = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(local.module_tags, {
    Name        = "${var.name}-private-${each.key}"
    Environment = var.environment
    Tier        = "private"
  })
}

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  domain = "vpc"

  tags = merge(local.module_tags, {
    Name        = "${var.name}-nat-eip"
    Environment = var.environment
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = var.nat_gateway_az != null ? aws_subnet.public[var.nat_gateway_az].id : values(aws_subnet.public)[0].id

  tags = merge(local.module_tags, {
    Name        = "${var.name}-nat"
    Environment = var.environment
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.module_tags, {
    Name        = "${var.name}-public"
    Environment = var.environment
    Tier        = "public"
  })
}

resource "aws_route_table" "private" {
  count = var.enable_nat_gateway ? 1 : 0

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }

  tags = merge(local.module_tags, {
    Name        = "${var.name}-private"
    Environment = var.environment
    Tier        = "private"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = var.enable_nat_gateway ? aws_subnet.private : {}

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[0].id
}

# Lock down the auto-created default security group.
# Empty ingress/egress blocks mean: no rules — workloads can't accidentally rely on permissive defaults.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name        = "${var.name}-default-sg-locked"
    Environment = var.environment
  })
}
