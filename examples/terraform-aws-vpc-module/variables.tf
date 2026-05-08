variable "name" {
  description = "Name prefix for tagged resources (e.g., \"prod\", \"shared-services\")"
  type        = string
}

variable "cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR (e.g., 10.0.0.0/16)."
  }

  nullable = false
}

variable "environment" {
  description = "Environment name for resource tagging"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }

  nullable = false
}

variable "public_subnets" {
  description = "Public subnet CIDRs keyed by AZ name (e.g., {\"us-east-1a\" = \"10.0.0.0/20\"})"
  type        = map(string)
}

variable "private_subnets" {
  description = "Private subnet CIDRs keyed by AZ name (e.g., {\"us-east-1a\" = \"10.0.64.0/20\"})"
  type        = map(string)
}

variable "enable_nat_gateway" {
  description = "Whether to provision a single NAT gateway for private subnet egress"
  type        = bool
  default     = false

  nullable = false
}

variable "nat_gateway_az" {
  description = "AZ name to host the NAT gateway. When null, selects the lexicographically-first AZ from public_subnets — set explicitly to pin AZ identity across plans."
  type        = string
  default     = null

  validation {
    condition     = var.nat_gateway_az == null || contains(keys(var.public_subnets), var.nat_gateway_az)
    error_message = "nat_gateway_az must be one of the keys in public_subnets, or null to auto-select."
  }
}

variable "enable_dns_hostnames" {
  description = "Whether to enable DNS hostnames in the VPC"
  type        = bool
  default     = true

  validation {
    condition     = !var.enable_dns_hostnames || var.enable_dns_support
    error_message = "enable_dns_hostnames = true requires enable_dns_support = true (AWS API constraint)."
  }

  nullable = false
}

variable "enable_dns_support" {
  description = "Whether to enable DNS resolution in the VPC"
  type        = bool
  default     = true

  nullable = false
}

variable "tags" {
  description = "Caller-supplied tags merged into per-resource defaults"
  type        = map(string)
  default     = {}

  nullable = false
}
