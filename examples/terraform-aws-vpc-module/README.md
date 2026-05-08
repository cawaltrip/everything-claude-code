# terraform-aws-vpc-module — Reference Module

> **Reference only.** This module is shipped with ECC to demonstrate the patterns from `skills/terraform-patterns/SKILL.md`.
> It is **not** published to a public Terraform registry. Copy + adapt for your own repo; do not consume directly via `module "vpc" { source = "..." }`.

## What It Demonstrates

- **Module hierarchy**: this is a *resource module* (single logical group: VPC + subnets + IGW + NAT + routing + default-SG lockdown).
- **File organization**: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md` — every standard file present, no `terraform.tfvars`/`backend.tf`/`provider.tf` (those belong at composition).
- **Identity stability**: subnets keyed by AZ via `for_each` over `map(string)` — adding/removing an AZ touches only that subnet.
- **Boolean toggle**: NAT gateway, EIP, private route table, and private route-table associations all gated by `count = var.enable_nat_gateway ? 1 : 0` and `for_each = var.enable_nat_gateway ? aws_subnet.private : {}`.
- **Version pinning**: `~> 1.9` runtime floor, `~> 5.0` AWS provider major-pin.
- **Block ordering**: every resource uses `count`/`for_each` → arguments → `tags` → `depends_on`.
- **Variable contracts**: every variable has `description`, `nullable = false` where defaulted, validation where the value space is finite.
- **Outputs**: descriptive names; collection outputs return AZ-keyed maps; `try()` for safe singletons; `description` on every output; no `this_` prefix.
- **Security defaults**: default SG locked down, no inline SG rules, no `0.0.0.0/0` ingress, tags on every resource via `local.module_tags`.
- **OpenTofu/Terraform parity**: pure HCL, no TF-only or OT-only features — `tofu init && tofu plan` and `terraform init && terraform plan` produce identical results.

## Usage (in a composition)

```hcl
# environments/prod/main.tf
module "vpc" {
  source = "../../modules/networking" # NOT this examples/ path; adapt for your repo

  name        = "prod"
  cidr_block  = "10.0.0.0/16"
  environment = "prod"

  public_subnets  = { "us-east-1a" = "10.0.0.0/20", "us-east-1b" = "10.0.16.0/20" }
  private_subnets = { "us-east-1a" = "10.0.64.0/20", "us-east-1b" = "10.0.80.0/20" }

  enable_nat_gateway = true

  tags = {
    Owner      = "platform"
    CostCenter = "infra"
  }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — (required) | Name prefix for tagged resources (e.g., `"prod"`, `"shared-services"`) |
| `cidr_block` | `string` | `"10.0.0.0/16"` | CIDR block for the VPC |
| `environment` | `string` | `"dev"` | Environment name for resource tagging (`dev` / `staging` / `prod`) |
| `public_subnets` | `map(string)` | — (required) | Public subnet CIDRs keyed by AZ name |
| `private_subnets` | `map(string)` | — (required) | Private subnet CIDRs keyed by AZ name |
| `enable_nat_gateway` | `bool` | `false` | Whether to provision a single NAT gateway for private subnet egress |
| `nat_gateway_az` | `string` | `null` | AZ name to host the NAT gateway. `null` auto-selects the lex-first AZ; set explicitly to pin |
| `enable_dns_hostnames` | `bool` | `true` | Whether to enable DNS hostnames in the VPC |
| `enable_dns_support` | `bool` | `true` | Whether to enable DNS resolution in the VPC |
| `tags` | `map(string)` | `{}` | Caller-supplied tags merged into per-resource defaults |

## Outputs

| Name | Type | Description |
|---|---|---|
| `vpc_id` | `string` | ID of the VPC |
| `vpc_cidr_block` | `string` | CIDR block of the VPC |
| `internet_gateway_id` | `string` | ID of the Internet Gateway |
| `public_subnet_ids` | `map(string)` | IDs of the public subnets, keyed by AZ |
| `private_subnet_ids` | `map(string)` | IDs of the private subnets, keyed by AZ |
| `nat_gateway_id` | `string` | ID of the NAT Gateway, or empty string when disabled |
| `public_route_table_id` | `string` | ID of the public route table |
| `private_route_table_id` | `string` | ID of the private route table, or empty string when NAT disabled |
| `default_security_group_id` | `string` | ID of the locked-down default security group |

## What It Does NOT Demonstrate

- **Multi-account or multi-region wiring** — composition concern; out of scope for a resource module.
- **Multi-AZ NAT (one NAT per private subnet)** — production-recommended for HA but adds 20+ lines; users adapting for prod should switch to one NAT per AZ.
- **Default route table / network ACL lockdown** — module locks the default security group via `aws_default_security_group`, but the default route table and default network ACL inside the created VPC remain at AWS defaults. Adding `aws_default_route_table` and `aws_default_network_acl` resources (~30 lines) is the right move for a hardened security baseline — deferred here to keep the fixture focused on iteration patterns. Workloads should never be placed in the default route table or default NACL regardless.
- **VPC flow logs** — best-practice but requires a destination bucket / log group, which adds a data-resource dependency this module deliberately omits.
- **IPv6** — doubles the variable surface; deferred to a future revision.
- **Application-tier security groups** — belong in a compute or web-application module, not a networking resource module.
- **IAM policy authoring** — covered in `skills/terraform-security/SKILL.md` IAM Discipline.
- **RDS / S3 / EBS encryption** — data resources are out of scope; covered in `skills/terraform-security/SKILL.md` Encryption at Rest.
- **Mock-provider tests (`*.tftest.hcl`)** — this module is a fixture for the testing skill if you want to write tests against it, but no tests ship here.

## Relationships

- **Pattern source**: `skills/terraform-patterns/SKILL.md`
- **Security baseline**: `skills/terraform-security/SKILL.md` pre-apply checklist
- **Review pass**: `agents/terraform-reviewer.md` should report 0 CRITICAL / 0 HIGH findings on this module

---

> Adapted from terraform-skill and terraform-best-practices by Anton Babenko (Apache-2.0).
