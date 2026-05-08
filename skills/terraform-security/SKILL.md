---
name: terraform-security
description: IaC-class security checklist for Terraform and OpenTofu — state-stored secret hygiene, encryption defaults, security-group hygiene, default-VPC avoidance, write-only / password_wo arguments, ephemeral values, OpenTofu state encryption, and scanner integration patterns. Auto-activates on prompts like "is this terraform module secure", "harden this terraform module", "harden this IaC", "check for state-secret leakage", "IaC vulnerability scan", "is this terraform compliant with HIPAA/PCI/SOC2", or any IaC-tagged security/hardening prompt on .tf/.tofu/.tfvars files.
origin: ECC
---

# Terraform/OpenTofu Security

IaC-class security depth for Terraform and OpenTofu modules. The state file is the crown jewel — anything stored in it is a compliance artifact and should be treated as a secret. Literal values committed to `.tf` defaults persist forever (state, plans, CI logs, registry caches). `sensitive = true` is a display mask, not a state guard. Cloud-vendor defaults (default VPC, open egress, AES-256 SSE) are unsafe for regulated workloads. This skill is the depth surface for the IaC summary at `rules/terraform/security.md` and the agent priorities at `agents/terraform-reviewer.md`.

## When to Activate

- Adding any data-bearing resource (RDS, S3, EBS, DynamoDB, Secrets Manager)
- Authoring or reviewing security groups, NACLs, or other network controls
- Configuring providers, backends, or remote state buckets
- Planning a secret rotation or onboarding a new external secret store
- Hardening a module for compliance (HIPAA, PCI, FedRAMP, SOC 2)
- Integrating IaC scanners — `tflint`, `trivy config`, `checkov`
- Bumping the AWS provider major version (v4 → v5 unlocks `aws_vpc_security_group_*_rule`)
- Migrating state-at-rest (S3 SSE-S3 → SSE-KMS, or to OpenTofu native state encryption)

## State Secret Hygiene

Terraform/OpenTofu state stores plaintext values for every resource argument including those marked `sensitive = true`. The `sensitive` attribute masks values in CLI display only — the value still lives in `terraform.tfstate` and any state backups, plan artifacts, and CI logs that touched it.

True state exclusion requires one of three mechanisms, in this order of preference:

| Mechanism | Version floor | What it excludes |
|---|---|---|
| `password_wo` / `*_wo` (write-only argument) | TF 1.11+, AWS provider 5.71+ | The argument value never lands in state |
| `ephemeral` (resource or value) | TF 1.10+ | The value exists only during apply; never written to state |
| `manage_master_user_password = true` | AWS provider 5.x+ (RDS only) | AWS manages the password lifecycle in Secrets Manager directly |

### ❌ DON'T: Literal secret in variable default

```hcl
# ❌ Persists in state, plan output, and repo history
variable "database_password" {
  type    = string
  default = "SuperSecret123!"
}
```

### ✅ DO: Reference a runtime secret, or use a write-only argument

```hcl
# ✅ TF 1.11+ / AWS provider 5.71+: password_wo never lands in state
resource "aws_db_instance" "this" {
  password_wo         = var.database_password_wo
  password_wo_version = 1
}

# Recommended for RDS specifically: AWS-managed password in Secrets Manager
resource "aws_db_instance" "managed" {
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.db.arn
}
```

Bumping `password_wo_version` triggers rotation on the next apply without changing the secret value in code.

### ❌ DON'T: Treat `sensitive = true` as state exclusion

```hcl
# ❌ random_password.result and any consuming argument land in state plaintext
resource "random_password" "db" {
  length = 32
}

resource "aws_db_instance" "this" {
  password = random_password.db.result
}
```

### ✅ DO: Use `ephemeral` for true state exclusion (TF 1.10+)

```hcl
# ✅ ephemeral values exist only in the apply graph; never written to state
ephemeral "random_password" "db" {
  length = 32
}

resource "aws_db_instance" "this" {
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = 1
}
```

> **Caveat — `aws_secretsmanager_secret_version` data source.** Reading `secret_string` via the data source persists the value in state on every refresh. For RDS, prefer `manage_master_user_password = true`. For other consumers, use an `ephemeral` provider/resource (TF 1.10+) or inject via a CI environment variable outside Terraform.
>
> **Caveat — `nonsensitive()`.** Use it only when a value derived from sensitive inputs is genuinely safe to expose (e.g., a hash). Stripping a secret to silence plan output leaks it to every CI job that prints the plan.

## Encryption at Rest

Encrypt every data resource. For regulated workloads (HIPAA, PCI, FedRAMP), customer-managed CMK with key rotation is typically required — SSE-S3 (`AES256`) is AWS-managed and produces no per-request CloudTrail audit trail.

### ❌ DON'T: Skip encryption or rely on bucket-level default

```hcl
# ❌ No SSE configuration; bucket-level default may be SSE-S3 with no audit trail
resource "aws_s3_bucket" "data" {
  bucket = "my-app-data"
}
```

### ✅ DO: Customer-managed KMS with rotation, on every data resource

```hcl
# ✅ S3 with SSE-KMS + bucket key (controls per-request KMS costs)
resource "aws_kms_key" "data" {
  description             = "App data encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_db_instance" "this" {
  storage_encrypted = true
  kms_key_id        = aws_kms_key.data.arn
  # ...
}

resource "aws_ebs_volume" "this" {
  encrypted  = true
  kms_key_id = aws_kms_key.data.arn
  size       = 100
}
```

## Default VPC Avoidance

### ❌ DON'T: Place workloads in the default VPC

```hcl
# ❌ Default VPC has public subnets and an account-wide SG
resource "aws_instance" "app" {
  ami       = "ami-12345"
  subnet_id = "subnet-default"
}
```

### ✅ DO: Dedicated VPC with explicit private subnets

```hcl
# ✅ Workloads land in private subnets; public subnets reserved for ALB/bastion
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "app-vpc" }
}

resource "aws_subnet" "private" {
  for_each          = toset(["us-east-1a", "us-east-1b"])
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(aws_vpc.this.cidr_block, 8, index(["us-east-1a", "us-east-1b"], each.value))
  availability_zone = each.value
  tags              = { Name = "app-private-${each.value}", Tier = "private" }
}
```

## Security Group Hygiene

### ❌ DON'T: Open SSH/RDP/DB ports to the world or use inline rules

```hcl
# ❌ World-open SSH and all-protocols ingress; inline rules force SG recreation on change
resource "aws_security_group" "web" {
  name   = "web"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### ✅ DO: Separate rule resources with stable identity (AWS provider v5+)

```hcl
# ✅ aws_vpc_security_group_*_rule (v5+): one rule per resource, stable identity
resource "aws_security_group" "web" {
  name        = "web"
  description = "Web tier"
  vpc_id      = aws_vpc.this.id
  # No inline rules — managed via separate resources below
}

locals {
  ingress_rules = {
    https_internal = {
      cidr_ipv4   = "10.0.0.0/16"
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      description = "HTTPS from internal VPC"
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each          = local.ingress_rules
  security_group_id = aws_security_group.web.id
  description       = each.value.description
  cidr_ipv4         = each.value.cidr_ipv4
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.ip_protocol
}

resource "aws_vpc_security_group_egress_rule" "https_out" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS to external services"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
```

On AWS provider v4, the next-best option is `aws_security_group_rule` (older non-VPC-specific resource, still safe but with weaker identity guarantees).

## State File Security

Local state (`./terraform.tfstate`) is for personal scratch only. Any module other engineers or CI jobs touch must use a remote backend: S3 + DynamoDB lock, S3 + native lockfile (TF 1.10+), TF Cloud / HCP Terraform, GCS, Azure Storage. Local state on shared infra is a state-corruption incident waiting to happen.

```hcl
# State bucket — versioning ON, SSE-KMS with CMK, public-access-block ON, lifecycle expiry
resource "aws_s3_bucket" "tfstate" {
  bucket = "acme-terraform-state"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_kms_key" "tfstate" {
  description             = "Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}

# Lock table — pay-per-request, prevent_destroy on the table itself
resource "aws_dynamodb_table" "tflock" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  lifecycle { prevent_destroy = true }
}
```

The bucket policy should `Deny s3:*` when `aws:SecureTransport = false` to enforce TLS. Restrict access via IAM role + bucket policy; never expose the state bucket publicly.

## OpenTofu State Encryption (OT 1.7+ — OpenTofu only)

OpenTofu 1.7+ ships native state encryption that does not depend on backend SSE. The encryption block is part of the language, not a backend feature, so it works against any backend (local, S3 without bucket-level KMS, GCS, etc.):

```hcl
# OpenTofu only (OT 1.7+) — applies to any backend
terraform {
  encryption {
    key_provider "pbkdf2" "by_passphrase" {
      passphrase = var.tfstate_passphrase   # supply via env: TF_VAR_tfstate_passphrase
    }

    method "aes_gcm" "by_passphrase" {
      keys = key_provider.pbkdf2.by_passphrase
    }

    state {
      method   = method.aes_gcm.by_passphrase
      enforced = true   # rejects unencrypted reads after migration
    }

    plan {
      method = method.aes_gcm.by_passphrase
    }
  }
}
```

Migration note: rotating from passphrase to a KMS key provider mid-flight requires changing the `state` method AND setting `enforced = true` to lock out unencrypted reads. Do the rotation in a single apply; splitting it across two compositions leaves state half-encrypted under the old method and half under the new.

This feature is OpenTofu-only. Terraform users get state-at-rest encryption via backend SSE (S3 bucket KMS, etc.) instead.

## Scanner Integration

Scanner ordering and gate behavior are owned by `rules/terraform/hooks.md`. This skill explains *what* to scan for and how to tune each tool; the rules layer explains *when* to scan. Stop-hook ordering is `tflint --recursive` → `trivy config .` → `checkov -d .`. Detect-and-skip with a stderr warning if any tool is missing — never block on a missing scanner.

```hcl
# .tflint.hcl — commit alongside the module; run `tflint --init` once on checkout
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_required_version"      { enabled = true }
rule "terraform_required_providers"    { enabled = true }
rule "terraform_unused_declarations"   { enabled = true }
```

```bash
trivy config . --severity HIGH,CRITICAL
```

```text
# .trivyignore — one rule per line, leading reason as a comment
# AVD-AWS-0058: bucket logging not required for tfstate (audit trail in CloudTrail)
AVD-AWS-0058
```

```yaml
# .checkov.yaml
framework:
  - terraform
quiet: true
skip-check:
  # CKV_AWS_19: SSE managed via separate aws_s3_bucket_server_side_encryption_configuration
  - CKV_AWS_19
```

**Suppression discipline.** Never blanket-suppress severity tiers. Every suppression must (a) name the specific rule ID, (b) state the documented reason in the suppression file or PR description, (c) include an expiry date or follow-up ticket if the suppression is temporary. A suppression without a reason is indistinguishable from a missed finding six months later.

## IAM Discipline

### ❌ DON'T: Wildcard god-mode policies

```hcl
# ❌ Action="*" + Resource="*" is god-mode; reserve for break-glass roles only
resource "aws_iam_policy" "bad" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "*"
      Resource = "*"
    }]
  })
}
```

### ✅ DO: Explicit action list, scoped resource ARNs

```hcl
# ✅ Specific actions, scoped ARNs; separate read and write roles
resource "aws_iam_policy" "app_read" {
  name = "app-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${aws_s3_bucket.data.id}",
        "arn:aws:s3:::${aws_s3_bucket.data.id}/*",
      ]
    }]
  })
}
```

Use tag-based ABAC (`aws:ResourceTag/Owner`) when multiple teams share an account so a single permission grant scales across resources without rewriting policies. For policy-document iteration patterns over many statements, see `skill: terraform-patterns` (count vs for_each section) — IAM policies benefit from the same identity-stable iteration discipline as any other resource.

## Pre-apply IaC Security Checklist

Run before every `apply` (or merging a change to `main`):

| Check | What "pass" looks like |
|---|---|
| No literal secrets | No `default = "..."` strings that look like credentials in `.tf`/`.tfvars`/defaults |
| Sensitive arguments reviewed | Every `sensitive = true` reviewed; `password_wo` used where TF ≥ 1.11 and value must not persist |
| Remote backend configured | No local state for shared infra; lock mechanism (S3 lockfile or DynamoDB) provisioned |
| State bucket hardened | Versioning ON, encryption SSE-KMS, public-access-block ON, lifecycle expiry, TLS-only bucket policy |
| Providers + modules pinned | Every entry in `required_providers` has a `version`; module sources have a `version` or commit ref |
| `versions.tf` declares `required_version` | Floor pinned (e.g., `~> 1.11`); reflects features actually used |
| No `0.0.0.0/0` ingress on SSH/RDP/DB | All ingress sources are specific CIDR or SG references |
| No inline `ingress`/`egress` blocks | `aws_vpc_security_group_*_rule` (v5+) or `aws_security_group_rule` (v4) used instead |
| All taggable resources tagged | Owner, Environment, CostCenter, Compliance tags as applicable |
| Encryption at rest on every data resource | S3 SSE-KMS, RDS `storage_encrypted = true`, EBS `encrypted = true`, DynamoDB SSE |
| Default VPC unused | Workloads land in a dedicated VPC with explicit subnets |
| `tflint` clean | `tflint --format compact` returns 0 OR every suppression documented in `.tflint.hcl` |
| `trivy config .` clean | HIGH/CRITICAL findings resolved OR documented in `.trivyignore` |
| `checkov -d .` clean | Findings resolved OR documented in `.checkov.yaml` |

## Cross-References

- **Patterns and idioms**: skill: `terraform-patterns`
- **Workflow-shaped review framing**: skill: `terraform-review`
- **Test framework choice / assertions**: skill: `terraform-testing`
- **Reviewer agent (severity-classified findings)**: agent: `terraform-reviewer`
- **Build / init / validate / plan / apply error repair**: agent: `terraform-build-resolver`
- **Rules summary surfaces**: `rules/terraform/security.md` (IaC summary), `rules/terraform/hooks.md` (scanner gate ordering)

**Remember**: state is the crown jewel — `password_wo` and `ephemeral` are the only true state-exclusion tools (`sensitive` is just a display mask); default VPC, default SG, and `0.0.0.0/0` ingress are unsafe baselines; pin every provider and module version; let scanners run at Stop-time only and never blanket-suppress a severity tier.

---

> Adapted from terraform-skill and terraform-best-practices by Anton Babenko (Apache-2.0).
