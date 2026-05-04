---
name: terraform-patterns
description: Idiomatic Terraform and OpenTofu patterns for module structure, naming, block ordering, count vs for_each, locals, version management, and modern HCL features for building maintainable infrastructure modules.
origin: ECC
---

# Terraform/OpenTofu Patterns

Idiomatic Terraform and OpenTofu patterns for writing maintainable infrastructure modules — module hierarchy, file organization, naming, block ordering, identity-stable iteration, version-floor-aware modern features, and inline OpenTofu divergence.

## When to Use

- Writing new Terraform or OpenTofu modules
- Reviewing or refactoring existing TF/OT modules
- Designing module hierarchy (resource module vs infrastructure module vs composition)
- Choosing between `count` and `for_each` for a collection of resources
- Planning a refactor that needs `moved` blocks to avoid destroy/create churn
- Bumping provider or runtime versions and deciding constraint syntax
- Authoring a module that targets both Terraform and OpenTofu runtimes

## How It Works

This skill covers seven areas: a four-level module hierarchy (resource → resource module → infrastructure module → composition) with standard file organization; naming canon for resources, variables, and outputs; strict block ordering for resources, variables, and outputs; identity-stable iteration that picks `for_each` over `count` whenever items might reorder, with `moved` blocks for safe refactoring; locals as a deletion-order discipline for optional resources; version-floor-aware modern features tied to a guard table that names the common LLM-error pattern per feature; and OpenTofu divergence inlined as `{terraform|tofu}` CLI notation throughout, so a single skill body covers both runtimes.

## Module Hierarchy

Three levels of abstraction, plus the resource itself.

| Type | Scope | Example |
|------|-------|---------|
| **Resource** | A single API object | `aws_vpc`, `aws_db_instance` |
| **Resource module** | Tightly coupled resources that always work together | VPC + subnets + route tables; security group + rules |
| **Infrastructure module** | Multiple resource modules for one purpose, scoped to one region/account | "Web application" stack: VPC + ALB + ECS + RDS |
| **Composition** | Top-level entry, spans regions/accounts | `environments/prod/`, `environments/staging/` |

Flow: resource → resource module → infrastructure module → composition. Smaller scopes mean smaller blast radius and faster `{terraform|tofu} plan` cycles.

### Directory Layout

```text
my-project/
├── environments/        # Compositions — top-level entry points
│   ├── prod/
│   │   ├── main.tf
│   │   ├── backend.tf
│   │   ├── terraform.tfvars
│   │   └── variables.tf
│   ├── staging/
│   └── dev/
├── modules/             # Reusable modules
│   ├── networking/      # Resource module
│   ├── compute/         # Resource module
│   ├── data/            # Resource module
│   └── web-application/ # Infrastructure module (composes resource modules)
└── examples/
    ├── minimal/
    └── complete/
```

Separate **environments** from **modules**. Use `examples/` as both documentation and integration fixtures. Keep modules small and single-responsibility — split state by env+component for prod (`prod/networking/`, `prod/compute/`, `prod/data/`).

> Depth on state organization, multi-team isolation, and backend migration lives in agent: `terraform-build-resolver` for recovery and the rules layer for everyday discipline.

### File Organization

Required files in every module:

- `main.tf` — resources, data sources, module calls
- `variables.tf` — typed inputs with `description`
- `outputs.tf` — typed outputs with `description`
- `versions.tf` — `required_version` + `required_providers`

Conditional files:

- `terraform.tfvars` — **only** at composition level, never inside reusable modules
- `backend.tf` — only at composition level (remote state config)
- `locals.tf` — when `main.tf` grows past ~200 lines and locals dominate
- `data.tf` — when data sources dominate `main.tf`

Standard file names match exactly — never `vars.tf`, `out.tf`, or `terraform.tf`.

## Naming Conventions

### General

- Use `_` (underscore) instead of `-` (dash) in all Terraform identifiers — resource names, data source names, variable names, output names, local names, module instance names.
- Prefer lowercase letters and numbers. UTF-8 is supported; don't use it for cleverness.
- Cloud resource argument *values* (the `name = "..."` arg of an `aws_security_group`, the DNS-bound name of an RDS instance, etc.) often DO use `-`; that's the cloud's constraint, not Terraform's.

### Resources and Data Sources

```hcl
# ✅ GOOD
resource "aws_route_table" "public" { /* ... */ }
resource "aws_route_table" "private" { /* ... */ }
resource "aws_nat_gateway" "this" { /* singleton */ }

# ❌ BAD - resource type repeated in name
resource "aws_route_table" "public_route_table" { /* ... */ }

# ❌ BAD - vague name when a descriptive one exists
resource "aws_instance" "main" { /* ... */ }
```

- Don't repeat the resource type in the resource name (`aws_instance.web_server`, not `aws_instance.web_server_instance`).
- Reserve `this` for genuine singletons — a module that creates exactly one of a thing. If a module creates multiple `aws_route_table` resources but exactly one `aws_nat_gateway`, the NAT gateway is `this` and the route tables get descriptive names.
- Use singular nouns for names; plurals belong on outputs that return lists.

### Variables

```hcl
# ✅ GOOD
variable "vpc_cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
  nullable    = false
}

variable "availability_zones" {
  description = "List of AZ names to deploy subnets into"
  type        = list(string)
}

variable "encryption_enabled" {
  description = "Whether to enable encryption at rest"
  type        = bool
  default     = true
}

# ❌ BAD - too vague, no context prefix
variable "cidr" { type = string }

# ❌ BAD - double negative
variable "encryption_disabled" { type = bool }
```

- Prefix with context (`vpc_cidr_block`, not `cidr`) so a caller setting the variable from a `tfvars` file can tell what it controls.
- Plural names for `list(...)` and `map(...)` types.
- Set `nullable = false` (1.1+) when `null` should fall back to `default` instead of overriding it.
- Avoid double negatives — `encryption_enabled = true` reads cleaner than `encryption_disabled = false`.
- Always include `description`. Borrowing wording from the resource's "Argument Reference" upstream is fine.

### Outputs

Pattern: `{name}_{type}_{attribute}`

```hcl
# ✅ GOOD
output "web_security_group_id" {
  description = "ID of the web tier security group"
  value       = aws_security_group.web.id
}

output "private_subnet_ids" {  # plural for list
  description = "IDs of the private subnets, ordered by AZ"
  value       = aws_subnet.private[*].id
}

output "vpc_id" {  # `this_` prefix omitted for singleton
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

# ❌ BAD - `this_` prefix leaks into the public surface
output "this_security_group_id" {
  value = aws_security_group.this[0].id
}

# ❌ BAD - singular name returning a list
output "subnet_id" {
  value = aws_subnet.private[*].id
}
```

- Always include `description`.
- Plural names when the value is a list.
- Drop the `this_` prefix on outputs from singleton resources — the consumer doesn't care that the module's internal name is `this`.
- Prefer `try(...)` over `element(concat(...))` for safe fallbacks (0.12.20+).

## Block Ordering

### Resource Blocks

Strict ordering inside every resource block:

1. `count` or `for_each` first, with a blank line after
2. Arguments (alphabetical or logical grouping)
3. `tags` as the last real argument
4. `depends_on` after `tags`
5. `lifecycle` at the very end

```hcl
# ✅ GOOD
resource "aws_nat_gateway" "this" {
  count = var.create_nat_gateway ? 1 : 0

  allocation_id = aws_eip.this[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${var.name}-nat"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.this]

  lifecycle {
    create_before_destroy = true
  }
}

# ❌ BAD - count buried in middle, tags before arguments, lifecycle before depends_on
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.this[0].id
  tags          = { Name = "nat" }
  count         = var.create_nat_gateway ? 1 : 0
  subnet_id     = aws_subnet.public[0].id

  lifecycle { create_before_destroy = true }
  depends_on = [aws_internet_gateway.this]
}
```

### Variable Blocks

Strict ordering inside every variable block:

1. `description` (always required)
2. `type`
3. `default`
4. `validation`
5. `nullable`
6. `sensitive`

```hcl
# ✅ GOOD
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

### Output Blocks

1. `description` (always required)
2. `value`
3. `sensitive` (only when needed; see caveat below)

```hcl
output "security_group_id" {
  description = "ID of the security group, or empty string if not created"
  value       = try(aws_security_group.this[0].id, "")
}
```

`sensitive = true` masks display only — the value still lands in state. For real secret material, see the cross-reference at the end of this skill.

## count vs for_each

### Decision Matrix

| Scenario | Use | Why |
|----------|-----|-----|
| Boolean toggle (create / don't) | `count = condition ? 1 : 0` | Optional singleton; cleanest single-resource conditional |
| Simple numeric replication of identical instances | `count = N` | Order doesn't matter; items won't be added/removed |
| Items may reorder or be removed from middle | `for_each = toset(list)` | Stable resource addresses by key |
| Reference resources by a meaningful key | `for_each = map` | Named access (`aws_subnet.private["us-east-1a"]`) |
| Multiple named resources with per-instance config | `for_each` over `map(object(...))` | Stable identity + typed per-instance config |

**Never** use a list index as long-lived identity — removing a middle element reshuffles every address after it.

### When to Use `count`

```hcl
# ✅ GOOD - boolean toggle
resource "aws_nat_gateway" "this" {
  count = var.create_nat_gateway ? 1 : 0

  allocation_id = aws_eip.this[0].id
  subnet_id     = aws_subnet.public[0].id
}
```

For simple numeric replication of identical instances (e.g., N service-account IAM users keyed by `count.index`), `count = N` is acceptable as long as items will not be added or removed from the middle.

### When to Use `for_each`

```hcl
# ✅ GOOD - map keyed by AZ, fully order-independent
variable "private_subnets" {
  description = "Private subnet CIDRs keyed by AZ name"
  type        = map(string)
  # Example: { "us-east-1a" = "10.0.0.0/20", "us-east-1b" = "10.0.16.0/20", "us-east-1c" = "10.0.32.0/20" }
}

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = {
    Name = "private-${each.key}"
  }
}

# Reference: aws_subnet.private["us-east-1a"]
```

The map-keyed shape is fully order-independent — adding or removing an AZ touches only that subnet, and reordering touches nothing (maps are unordered). Avoid `for_each = toset(var.azs)` paired with `cidrsubnet(..., index(var.azs, each.key))`: the resource keys are stable, but the CIDR formula reintroduces list-order dependency. For per-instance config beyond a single CIDR (type, subnet, public/private placement), promote the value to `map(object(...))` — see *Plan-Time Key Resolution* below.

### Migration: count → for_each with `moved` blocks

Refactoring from `count` to `for_each` without `moved` blocks turns the rename into destroy/create. Always emit `moved` in the same change.

```hcl
# Before (using count over a list)
variable "availability_zones" {
  description = "AZs to deploy subnets into"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr_block, 8, count.index)
  availability_zone = var.availability_zones[count.index]
}

# Reference: aws_subnet.private[0].id
```

```hcl
# After (using for_each over a set keyed by AZ name)
resource "aws_subnet" "private" {
  for_each = toset(var.availability_zones)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr_block, 8, index(var.availability_zones, each.key))
  availability_zone = each.key
}

# Reference: aws_subnet.private["us-east-1a"].id

# Migration blocks — emit in the same change as the rename
moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["us-east-1a"]
}

moved {
  from = aws_subnet.private[1]
  to   = aws_subnet.private["us-east-1b"]
}

moved {
  from = aws_subnet.private[2]
  to   = aws_subnet.private["us-east-1c"]
}
```

**Verification**: `{terraform|tofu} plan` should show *moved* operations, not destroy/create. If you see destroy/create after adding `moved`, the from/to addresses are wrong.

After migration, removing `us-east-1b` destroys only that one subnet; adding a fourth AZ does not churn the existing three; addresses are stable by AZ name.

### Plan-Time Key Resolution

`for_each` keys must be resolvable at plan time. You cannot drive `for_each` from a value that won't exist until apply.

```hcl
# ❌ BAD - keys derived from computed IDs; plan fails with "Invalid for_each argument"
resource "aws_eip" "web" {
  for_each = toset([for i in aws_instance.web : i.id])
  instance = each.key
}

# ✅ GOOD - drive for_each from user-supplied keys; both resources share the key
variable "instances" {
  description = "Per-instance config keyed by stable name"
  type        = map(object({ instance_type = string }))
}

resource "aws_instance" "web" {
  for_each = var.instances

  ami           = data.aws_ami.this.id
  instance_type = each.value.instance_type
}

resource "aws_eip" "web" {
  for_each = var.instances

  instance = aws_instance.web[each.key].id
}
```

`depends_on` does not fix this — it orders applies, not plan-time value resolution. When the count of instances genuinely is unknown until apply, fall back to a `count = condition ? 1 : 0` singleton.

## Modern Features (1.0+)

### Feature Guard Table

Before emitting a feature, verify the runtime floor declared in `versions.tf`. Each row also names the common LLM-error pattern — the mistake to actively avoid.

| Feature | Min version | Common LLM error pattern |
|---------|-------------|--------------------------|
| `for_each` over `count` for stable identity | 0.12+ | defaults to `count` for every collection, causing index churn on insert/remove |
| `try()` function | 0.12.20+ | falls back to `element(concat(...))` legacy pattern |
| `nonsensitive()` function | 0.15+ | used to "unwrap" sensitive outputs into plan artifacts, leaking secrets into CI logs |
| `nullable = false` | 1.1+ | omits it, letting `null` silently override the `default` |
| `moved` blocks | 1.1+ | omitted during refactor, silently turning a rename into destroy/create |
| `optional()` with defaults | 1.3+ | emits wrapper variables and loose `map(any)` contracts instead |
| declarative `import` blocks | 1.5+ | recommends ad-hoc CLI `import` instead of a reviewable, VCS-tracked block |
| `check` blocks | 1.5+ | treats them as gating; `check` is advisory only |
| native test framework | 1.6+ | not used; over-relies on Terratest |
| mock providers | 1.7+ | asserts computed values in plan-only mode |
| `removed` blocks | 1.7+ | deletes resources from config without a lifecycle transition |
| provider-defined functions | 1.8+ | overuses data sources for simple transformations |
| cross-variable validation | 1.9+ | pushes checks into postconditions only |
| native S3 lock-file | 1.10+ | recommends DynamoDB lock table even on 1.10+ |
| `ephemeral` values | 1.10+ | conflated with `sensitive`; only `ephemeral` actually stays out of state |
| `write_only` arguments | 1.11+ | uses `sensitive = true` and assumes state is safe |

If the target runtime is below a feature floor, emit the pre-floor fallback explicitly instead of silently downgrading. This skill assumes 1.6+ unless your `versions.tf` says otherwise.

### Feature Spotlights

#### `try()` (0.12.20+)

```hcl
# ✅ GOOD
output "security_group_id" {
  description = "ID of the security group, or empty if not created"
  value       = try(aws_security_group.this[0].id, "")
}

# ❌ BAD - legacy pattern
output "security_group_id" {
  value = element(concat(aws_security_group.this[*].id, [""]), 0)
}
```

#### `nullable = false` (1.1+)

```hcl
variable "vpc_cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
  nullable    = false  # passing null uses default, not null
}
```

Without `nullable = false`, passing `null` silently overrides the default — a surprising override that yields `null` instead of the `default`, and a frequent source of "why is my CIDR null in state?".

#### `optional()` with Typed Defaults (1.3+)

```hcl
variable "database_config" {
  description = "Database configuration"
  type = object({
    name               = string
    engine             = string
    instance_class     = string
    backup_retention   = optional(number, 7)
    monitoring_enabled = optional(bool, true)
    extra_tags         = optional(map(string), {})
  })
}
```

Callers supply only the required fields; optional ones use the typed defaults. Prefer `optional()` with typed defaults over `map(any)` for module input contracts — the contract stays self-documenting and validated.

#### `moved` Blocks (1.1+)

```hcl
# Rename a resource
moved {
  from = aws_instance.web_server
  to   = aws_instance.web
}

# Move a resource into for_each
moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["us-east-1a"]
}

# Rename a module instance
moved {
  from = module.old_name
  to   = module.new_name
}
```

**Limits of `moved`** — it cannot cross every boundary:

| Boundary | Can `moved` cross? | Alternative |
|----------|--------------------|-------------|
| Provider | No | `removed` (1.7+) + `import` (1.5+) |
| Backend / state file | No | `state mv` across backends, with a pre-migration backup |
| A module that itself is being removed | Silently no-ops | put the `moved` in the **parent**, not the removed child |

#### `import` Blocks (1.5+)

Declarative, VCS-tracked imports beat the ad-hoc CLI `import` command on every dimension that matters: reviewable in a PR, replayable in CI, idempotent on re-apply.

```hcl
import {
  to = aws_s3_bucket.legacy_logs
  id = "my-existing-bucket-name"
}

resource "aws_s3_bucket" "legacy_logs" {
  bucket = "my-existing-bucket-name"
}
```

After the first apply that imports the resource, you can remove the `import` block in a follow-up change.

#### `write_only` Arguments (1.11+)

```hcl
# ✅ GOOD - write-only argument keeps the value out of state (1.11+)
data "aws_ssm_parameter" "db_password" {
  name            = "/prod/db/password"
  with_decryption = true
}

resource "aws_db_instance" "this" {
  engine         = "mysql"
  instance_class = "db.t3.micro"
  username       = "admin"

  password_wo = data.aws_ssm_parameter.db_password.value
}

# ❌ BAD - `sensitive = true` masks display only; the value still lands in state
variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
}

resource "aws_db_instance" "this" {
  password = var.db_password
}
```

A common LLM mistake is to mark a variable `sensitive = true` and assume the value is kept out of state — it is not. `sensitive` only masks terminal display.

> Depth on IaC-class secret management (runtime data sources, provider-managed passwords, ephemeral lookups, the full state-exclusion playbook) lives in skill: `terraform-security`.

#### `ephemeral` vs `sensitive` vs `nonsensitive`

| Goal | Use | Tradeoff |
|------|-----|----------|
| Short-lived credential that must never persist | `ephemeral` (1.10+) | Never in state or plan; provider/resource must support it |
| Value must persist but not display in CLI | `sensitive = true` | Still in state; masks terminal only |
| Derived non-secret incorrectly inferred as sensitive | `nonsensitive()` (0.15+) | Only safe when provably not secret; value enters plan output |

**Do not** use `nonsensitive()` to "fix" a sensitive value appearing in plan output — that laundering pattern leaks the secret into CI artifacts.

### Validation Mechanism Timing

Four mechanisms look similar; only three actually gate apply.

| Mechanism | When it runs | Can reference | Blocks apply? |
|-----------|--------------|---------------|---------------|
| `validation` (in `variable`) | var evaluation, before plan | the variable's own value; other vars on 1.9+ | **yes** |
| `precondition` (in `lifecycle`) | before resource create/update | other resources, data sources, vars | **yes** |
| `postcondition` (in `lifecycle`) | after apply | the resource's own computed attrs | **yes** |
| `check` block (1.5+) | every plan + apply | anything | **no — advisory only, warnings not errors** |

A common LLM mistake is to use `check` expecting it to gate apply. Use `precondition`/`postcondition` to gate; reserve `check` for ongoing health assertions you want logged but not blocking.

## Locals for Dependency Management

A specialized but high-leverage pattern: use a `local` with `try()` to hint the runtime about the correct deletion order when an optional resource sits between two required ones.

```hcl
# ✅ GOOD - local forces subnets to depend on the secondary CIDR association
locals {
  vpc_id = try(
    aws_vpc_ipv4_cidr_block_association.this[0].vpc_id,
    aws_vpc.this.id,
    ""
  )
}

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_vpc_ipv4_cidr_block_association" "this" {
  count = var.add_secondary_cidr ? 1 : 0

  vpc_id     = aws_vpc.this.id
  cidr_block = "10.1.0.0/16"
}

resource "aws_subnet" "secondary" {
  vpc_id     = local.vpc_id  # implicit dep on CIDR association
  cidr_block = "10.1.0.0/24"
}
```

Without the local, the runtime may try to delete the CIDR association before the subnets that depend on it, producing a "subnet still in use" error mid-destroy. The local creates an implicit dependency that forces the correct order without an explicit `depends_on`.

**Reach for this pattern when**: an optional resource (created via `count = condition ? 1 : 0`) sits between two required resources in the dependency graph. **Do not** reach for this every time you have a conditional resource — most don't have lifecycle ordering issues. Common fits: VPC + secondary CIDR + subnets; VPC + endpoint + route table associations.

## Version Management

### Constraint Strategy by Component

| Component | Constraint | Example | Rationale |
|-----------|------------|---------|-----------|
| Terraform / OpenTofu runtime | Pin minor | `required_version = "~> 1.9"` | Allows patch updates within the minor; protects against an accidental jump to 1.10's behavior changes |
| Providers | Pin major | `version = "~> 5.0"` | Allows minor + patch updates; new resources arrive on minor bumps, breaking changes wait for a major |
| Production module references | Pin exact | `version = "5.1.2"` | Prod is the wrong place to absorb upstream module changes silently |
| Dev / staging module references | Allow patch | `version = "~> 5.1"` | Catches issues with the new patch before prod sees them |

### Version Constraint Syntax

```hcl
# Pessimistic constraint (recommended)
version = "~> 5.0"      # >= 5.0, < 6.0     (allows 5.1, 5.2, ..., 5.99)
version = "~> 5.0.1"    # >= 5.0.1, < 5.1.0 (allows 5.0.x patches only)

# Range
version = ">= 5.0, < 6.0"

# Exact (use only when you mean it)
version = "5.1.2"

# Open-ended (avoid in production)
version = ">= 5.0"   # any 5.x or higher — including breaking 6.x
```

### Lock File Discipline

`{terraform|tofu} init` writes `.terraform.lock.hcl` with the exact provider versions selected within your constraints. Commit this file at the **composition** level — it pins what your last init saw. Do **not** commit a lock file inside reusable modules; the consumer's composition is what should pin.

```bash
# Update providers within your constraints
{terraform|tofu} init -upgrade

# Then review the lock-file diff before committing
git diff .terraform.lock.hcl
```

Keep provider/runtime upgrades in a **separate PR** from functional changes — when an upgrade breaks something, you want a clean revert.

### Example `versions.tf`

```hcl
terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
```

OpenTofu users with the OT registry change `source` to `opentofu/aws` (or use the OT registry endpoint); see OpenTofu Divergence below.

## OpenTofu Divergence

Through the 1.x series the languages are ~95% identical. Treat them as one runtime family with a small set of inline divergences.

### Divergence Table

| Surface | Terraform | OpenTofu | Notes |
|---------|-----------|----------|-------|
| Binary | `terraform` | `tofu` | Both parse `.tf` and `.tofu` files identically |
| Default registry | `registry.terraform.io` | `registry.opentofu.org` | OT mirrors most providers; module URIs may differ |
| State encryption | External (KMS at backend layer) | Built-in (1.7+) | OT-only: declarative `encryption {}` block in the `terraform` block |
| Provider iteration (`for_each` on `provider` blocks) | Not supported (use `configuration_aliases` for static aliasing) | OT 1.7+ | OT-only; no TF equivalent as of 1.x |

### Binary Detection Convention

When invoking the CLI from automation (hooks, CI, scripts):

- If `tofu` is on PATH, prefer it.
- If `ECC_TF_BINARY` env var is set, honor it (`terraform` or `tofu`).
- If neither is set and only `terraform` is on PATH, use `terraform`.
- The `terraform fmt` subcommand parses both `.tf` and `.tofu` syntax — usable as fallback if `tofu` is absent.

CLI commands in this skill use `{terraform|tofu}` notation so a single line covers both runtimes — pick your binary at read time.

> Hook gating, scanner deferral, and the per-project override mechanism live in [rules/terraform/hooks.md](../../rules/terraform/hooks.md).

### When to Branch

If a module specifically needs OT-only state encryption or an OT-only registry module, declare `required_version = ">= 1.7.0"` in `versions.tf` and document the OT-only assumption in the README. The runtime tooling cannot enforce "OT only" — `required_version` matches both binaries; the OT-only feature itself plus the README note are the practical guard.

## Quick Reference: TF/OT Idioms

| Idiom | Description |
|-------|-------------|
| `for_each` over `count` for stable identity | Use `for_each` whenever items might reorder, be removed, or need named access |
| `moved` in the same change as a rename | Without it, a rename becomes destroy/create silently |
| `try()` over `element(concat(...))` | The legacy pattern is a 0.12-era workaround; `try()` is the 0.12.20+ idiom |
| `~> X.Y` for runtime + provider pinning | Allows in-major drift, blocks breaking-major jumps |
| Plural names for list outputs | `private_subnet_ids`, not `private_subnet_id` |
| `this` only for genuine singletons | Multiple of the same type → descriptive names |
| `_` over `-` in HCL identifiers | Cloud resource argument values can use `-`; Terraform identifiers cannot |
| `validation` for input-time, `precondition`/`postcondition` for runtime | `check` is advisory and does not gate apply |
| Remote state, always | Local state is for throwaway one-off experiments only |
| `.terraform.lock.hcl` lives at composition | Reusable modules should not commit a lock file |
| Verify the runtime floor before emitting a feature | The Feature Guard Table names the version per feature |
| `nullable = false` for variables that should never be null | Otherwise `null` silently overrides `default` |
| `optional()` with typed defaults over `map(any)` | Self-documenting, validated, IDE-friendly |
| `password_wo` over `sensitive = true` for secret arguments (1.11+) | `sensitive` masks display, not state |
| `{terraform\|tofu}` notation for CLI in shared docs | Single source covers both runtimes |

## Anti-Patterns to Avoid

```hcl
# ❌ Bad: count over a list when items might reorder or be removed
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  availability_zone = var.availability_zones[count.index]
}

# ❌ Bad: rename without `moved` block — silently turns into destroy/create
# was: aws_instance.web_server; now: aws_instance.web; nothing else changed.

# ❌ Bad: `for_each` keys derived from computed IDs — plan fails
resource "aws_eip" "web" {
  for_each = toset([for i in aws_instance.web : i.id])
  instance = each.key
}

# ❌ Bad: assuming `sensitive = true` keeps a secret out of state
variable "db_password" {
  type      = string
  sensitive = true  # masks display only; the value lands in state
}

# ❌ Bad: `element(concat(...))` instead of `try()`
output "security_group_id" {
  value = element(concat(aws_security_group.this[*].id, [""]), 0)
}

# ❌ Bad: ad-hoc CLI `import` instead of declarative `import` blocks (1.5+)
# Loses VCS reviewability; not idempotent on re-apply.

# ❌ Bad: emitting a 1.11+ feature on a 1.5 runtime
# write_only / removed / native S3 lock all need a `versions.tf` floor check first.

# ❌ Bad: `ignore_changes = all` to silence noisy plans
resource "aws_db_instance" "this" {
  lifecycle {
    ignore_changes = all  # hides real drift; turns every attribute unmanaged
  }
}

# ❌ Bad: conflating `sensitive` with `ephemeral`
# `sensitive = true` keeps the value in state; `ephemeral` (1.10+) actually doesn't.

# ❌ Bad: `check` block expecting it to gate apply
# `check` is advisory; emits warnings, not errors. Use precondition/postcondition.

# ❌ Bad: `nonsensitive()` to "fix" a sensitive value in plan output
output "endpoint" {
  value = nonsensitive(aws_db_instance.this.password)  # leaks the secret to CI logs
}
```

**Remember**: pick `for_each` over `count` whenever identity matters; emit `moved` in the same change as a rename; verify the runtime floor before emitting a feature; never use a list index as long-lived identity; `sensitive = true` is a display mask, not a state guard.

> Depth on IaC-class security (state hardening, scanner integration, secret rotation, security-group hygiene) lives in skill: `terraform-security`. Test framework choice and assertion patterns live in skill: `terraform-testing`. Workflow-shaped review and build-fix flows live in agent: `terraform-reviewer` and agent: `terraform-build-resolver`.

---

> Adapted from terraform-skill and terraform-best-practices by Anton Babenko (Apache-2.0).
