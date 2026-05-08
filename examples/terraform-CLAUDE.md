# Terraform/OpenTofu Module Repo — Project CLAUDE.md

> Real-world example for an AWS Terraform/OpenTofu module repo with native test, mocked providers, and Stop-time scanners.
> Copy this to your project root and customize for your repo.

## Project Overview

**Stack:** Terraform 1.9+ / OpenTofu 1.9+, AWS provider v5, S3 + native lockfile (TF 1.10+) or S3 + DynamoDB (older), HCL, native test framework, mocked providers (TF 1.7+), Stop-time scanners (tflint / trivy / checkov)

**Architecture:** Three-tier module hierarchy — composition (`environments/`) → infrastructure module (`web-application/`) → resource module (`networking/`, `compute/`, `data/`). State remote, lock-file at composition, scanners deferred to Stop-hook (no mid-implementation churn).

## Critical Rules

### HCL Conventions

- `{terraform|tofu} fmt` is mandatory — PostToolUse hook runs it on every edited `.tf` file
- File names match exactly: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` — never `vars.tf`, `out.tf`, or `terraform.tf`
- Use `_` (underscore) in HCL identifiers — resource names, variable names, output names. Cloud resource argument *values* (e.g. `name = "my-vpc"`) can use `-`
- Every variable and output has a `description` — borrowing wording from the upstream resource's "Argument Reference" is fine
- Block ordering inside resources: `count`/`for_each` first → arguments → `tags` → `depends_on` → `lifecycle`
- Reusable modules never ship a `terraform.tfvars`, `backend.tf`, `provider` block, or committed `.terraform.lock.hcl` — those belong at the composition level
- Reserve `this` for genuine singletons; multiple resources of the same type get descriptive names

### State Hygiene

- Remote backend always — S3 + native lockfile (TF 1.10+) or S3 + DynamoDB. Local state is for throwaway one-off experiments
- `.terraform.lock.hcl` committed at composition only — never inside reusable modules
- `*.tfstate*` and `.terraform/` (the local plugin/module cache) are gitignored
- Sensitive arguments use `password_wo` (TF 1.11+) — `sensitive = true` masks display only, the value still lands in state
- No literal secrets in `.tf` defaults — load from a secret store or CI vault and pass as `TF_VAR_*`

```hcl
# BAD: literal secret as a default — lands in state on first apply
variable "db_password" {
  type    = string
  default = "Hunter2!Database"
}

# GOOD: write-only argument (TF 1.11+) — never lands in state
resource "aws_db_instance" "this" {
  password_wo = var.database_password
  password_wo_version = 1
}
```

### Identity Stability

- `for_each` over `count` whenever items might reorder, be removed, or need named access
- Never use a list index as long-lived identity — removing a middle element reshuffles every address after it
- Emit `moved` in the SAME change as a rename or a `count → for_each` refactor — without it, the rename silently becomes destroy/create
- `for_each` keys must resolve at plan time — driving `for_each` from a computed attribute fails with "Invalid for_each argument"
- Document state migration (`moved` blocks, `terraform state mv` commands) on PRs that change resource addresses

```hcl
# BAD: count over a list — removing us-east-1b reshuffles every subnet after it
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  availability_zone = var.availability_zones[count.index]
}

# GOOD: for_each over a map keyed by AZ — adding/removing an AZ touches only that subnet
resource "aws_subnet" "private" {
  for_each          = var.private_subnets
  availability_zone = each.key
  cidr_block        = each.value
}
```

### Version Pinning

- `required_version = "~> 1.9"` in every `versions.tf` — major-pin allows in-major drift, blocks 2.x jumps
- Providers pinned at major: `aws = "~> 5.0"`, `random = "~> 3.5"`. Production modules may pin tighter
- The `.terraform.lock.hcl` lives at the composition level only and pins what `init` last selected
- Keep provider/runtime upgrades in a **separate PR** from functional changes — clean revert on regression

### Security

- No `0.0.0.0/0` ingress on SSH, RDP, or database ports — restrict to known CIDRs or use SSM Session Manager
- Default security group always locked down via `aws_default_security_group` with empty `ingress` and `egress` — workloads can't accidentally rely on permissive defaults
- No inline `ingress`/`egress` blocks — use the AWS provider v5+ `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule` resources for stable identity
- Encryption at rest on every data resource: `storage_encrypted = true` on RDS, SSE-KMS on S3, `encrypted = true` on EBS volumes
- Default VPC never used — every workload deploys into an explicitly-created VPC
- Depth: see `skills/terraform-security/SKILL.md` for the full pre-apply checklist

### Testing

- Native `{terraform|tofu} test` (1.6+) is the default for HCL-only teams — no extra runtime, integrates with mocked providers
- Mock providers (TF 1.7+ / OT 1.7+) for cost-free unit-style tests of plan-time behavior
- Terratest only when the team has Go expertise OR the test scope spans modules that can't be exercised in a single `tftest.hcl`
- `command = apply` is REQUIRED in test runs that assert computed values or set-type nested blocks — mocked providers can't surface them in plan-only mode

### Hooks & Scanners

- PostToolUse runs `{terraform|tofu} fmt` on edited `.tf` files — idempotent, fast (<200ms typical)
- Stop-hook runs `tflint`, `trivy`, and `checkov` over touched directories — detect-and-skip per tool, never run mid-implementation
- Per-project override via `.claude/settings.local.json` — disable scanners for spike branches, re-enable before PR
- Canonical config and per-tool gating policy: `rules/terraform/hooks.md`

## File Structure

```
environments/        # Compositions — top-level entry points (terraform.tfvars + backend.tf live here)
  prod/
    main.tf
    backend.tf
    terraform.tfvars
    variables.tf
  staging/
  dev/
modules/             # Reusable modules (no backend, no provider config, no committed lock-file)
  networking/
    main.tf
    variables.tf
    outputs.tf
    versions.tf
  compute/
  data/
  web-application/   # Infrastructure module (composes resource modules)
examples/            # Module integration fixtures (referenced by `terraform test`)
  minimal/
  complete/
tests/               # Native `terraform test` files (*.tftest.hcl)
```

## Key Patterns

### Variable (Typed, Validated, Documented)

```hcl
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
```

### Resource (Block Ordering)

```hcl
resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = values(aws_subnet.public)[0].id

  tags = merge(local.module_tags, {
    Name = "${var.name}-nat"
  })

  depends_on = [aws_internet_gateway.this]
}
```

### `for_each` Keyed by AZ

```hcl
variable "private_subnets" {
  description = "Private subnet CIDRs keyed by AZ name"
  type        = map(string)
}

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = { Name = "private-${each.key}" }
}
```

### `moved` Block During Refactor

```hcl
# Was: resource "aws_subnet" "private" { count = length(var.azs) ... }
# Now: resource "aws_subnet" "private" { for_each = var.private_subnets ... }

moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["us-east-1a"]
}

moved {
  from = aws_subnet.private[1]
  to   = aws_subnet.private["us-east-1b"]
}
```

### Output (Plural List, Safe Singleton)

```hcl
output "private_subnet_ids" {
  description = "IDs of the private subnets, ordered by AZ"
  value       = [for s in aws_subnet.private : s.id]
}

output "security_group_id" {
  description = "ID of the security group, or empty string if not created"
  value       = try(aws_security_group.this[0].id, "")
}
```

## Environment Variables

```bash
# AWS
AWS_REGION=us-east-1
AWS_PROFILE=                                     # or use IAM role / instance profile

# Terraform/OpenTofu
TF_VAR_environment=prod                          # populates `var.environment` at plan/apply
TF_VAR_vpc_cidr_block=10.0.0.0/16
TF_PLUGIN_CACHE_DIR=~/.terraform.d/plugin-cache  # speeds repeated `init`
TF_LOG=                                          # set to DEBUG for verbose runtime traces

# ECC-specific
ECC_TF_BINARY=                                   # override binary detection: `terraform` or `tofu`. Default: tofu if on PATH.

# Sensitive (NOT in shell — load from your secret store / CI vault)
TF_VAR_database_password_wo=                     # TF 1.11+ write-only argument; never lands in state
```

## Testing Strategy

```bash
# Format check (PostToolUse-safe; idempotent)
{terraform|tofu} fmt -check -recursive

# Validate (HCL syntax + version compat)
{terraform|tofu} validate

# Lint (Stop-hook scope — see rules/terraform/hooks.md)
tflint --format compact

# Native test (TF 1.6+ / OT 1.6+)
{terraform|tofu} test

# Plan with output artifact (review before apply)
{terraform|tofu} plan -out=tfplan

# Stop-time scanner pipeline (also wired via Stop hook)
trivy config .
checkov -d .
```

> Every Terraform/OpenTofu task response follows the 5-section Response Contract: assumptions & version floor → risk category → chosen remediation & tradeoffs → validation plan → rollback notes. Canonical wording lives in `rules/terraform/patterns.md`. The `terraform-review` skill frames this contract automatically.

## ECC Workflow

- `skill: terraform-patterns` — module hierarchy, naming, block ordering, identity-stable iteration, version management
- `skill: terraform-security` — IaC-class security checklist (state secret hygiene, encryption, default-VPC avoidance, SG hygiene, scanner integration)
- `skill: terraform-testing` — test framework decision matrix, native test patterns, mock providers, set-type assertion handling
- `skill: terraform-mcp` (optional, when the HashiCorp Terraform MCP server is configured) — live provider/resource/module schema lookup
- `skill: terraform-review` — review workflow framing the Response Contract
- `agent: terraform-reviewer` — CRITICAL/HIGH/MEDIUM line-by-line review findings
- `agent: terraform-build-resolver` — fix `init`/`validate`/`plan`/`apply` errors with minimal diffs

> No `/terraform-*` slash commands. Skill auto-discovery + agent description-matching cover the workflows.

## Terraform vs. OpenTofu

Through 1.x the runtimes are ~95% identical. This CLAUDE.md uses `{terraform|tofu}` notation for shared CLI commands; pick your binary at read time.

- **Binary detection** (hooks): `tofu` is preferred if on PATH; override with `ECC_TF_BINARY=terraform`. See `rules/terraform/hooks.md`.
- **OT-only features** in this repo's modules: none currently — modules are pure 1.x HCL and run identically on either runtime.
- **State encryption**: if migrating to OpenTofu 1.7+ native state encryption, see `skills/terraform-security/SKILL.md`.

## Git Workflow

- Conventional commits: `feat:` new features, `fix:` bug fixes, `chore:` maintenance, `refactor:` internal restructure
- Feature branches from `main`, PRs required — never push directly to `main`
- CI runs `{terraform|tofu} fmt -check && validate && tflint && test` on every PR; a failing static-analysis pipeline blocks merge
- Plan-artifact required for any prod apply: `{terraform|tofu} plan -out=tfplan` reviewed in PR before `apply tfplan`

---

> Adapted from terraform-skill and terraform-best-practices by Anton Babenko (Apache-2.0).
