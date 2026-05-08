---
name: terraform-review
description: Workflow-shaped Terraform/OpenTofu review skill. Frames the Response Contract and routes review requests into the terraform-reviewer agent. Auto-activates on prompts like "review this terraform module", "audit this .tf file", "check this IaC", "is this module safe to apply", or any review/audit request on .tf/.tofu/.tfvars files.
origin: ECC
---

# Terraform/OpenTofu Review

Workflow-shaped skill that frames the Response Contract and routes review requests through the `terraform-reviewer` agent — the skill body sets expectations and triages by failure category, the agent produces the line-by-line findings. Depth on idiomatic patterns lives in skill: `terraform-patterns`. Depth on IaC-class security lives in skill: `terraform-security`. Test framework choice and assertion patterns live in skill: `terraform-testing`. Build, init, validate, plan, and apply error recovery lives in agent: `terraform-build-resolver`.

## When to Use

- Reviewing a new or modified Terraform/OpenTofu module
- Pre-merge review of a `.tf`/`.tofu`/`.tfvars` change
- Pre-apply audit on a plan artifact before promotion
- Drift triage when `{terraform|tofu} plan` shows unexpected diffs
- Refactors that touch `count`/`for_each`/`moved` blocks or rename resources
- Provider major-version bumps (e.g., AWS v4 → v5, AWS v5 → v6)
- Backend or state-storage migrations
- A reviewer asks "is this safe to apply?" without naming a specific concern

## How It Works

The skill auto-loads on review-shaped prompts (e.g. "review this terraform module", "audit this .tf", "is this safe to apply") and frames Claude's response in four legs:

1. **Skill consulted for shape** — this skill loads, sets contract expectations, and exposes the failure-category map.
2. **Response Contract applied** — the 5-section vocabulary from `rules/terraform/patterns.md` and `agents/terraform-reviewer.md` is used verbatim. Section names do not drift.
3. **Diagnose-first routing** — the failure-category map below routes the finding to the right deep skill or agent, so the reviewer's body lines up with the canonical reference for that risk class.
4. **Reviewer agent fires** — the `terraform-reviewer` agent produces line-by-line findings classified CRITICAL / HIGH / MEDIUM.

The agent uses these priorities — CRITICAL: state safety, identity stability, blast radius — HIGH: version pinning, state hygiene, module signature, module hygiene — MEDIUM: provider sync, best practices. The skill body previews these but does not duplicate the agent's content.

Skills cannot invoke agents directly; the value-add is the framing. When this skill is loaded, Claude routes correctly and emits the contract-shaped review the team agreed on.

## Response Contract

Every Terraform/OpenTofu review MUST include these five sections in this order, with these exact names. The reviewer agent recognizes these section headers; deviating breaks downstream tooling and makes findings hard to compare across reviews.

### 1. Assumptions & Version Floor

State the runtime context up front, even when the user did not provide it:

- **Runtime**: terraform or tofu (state which from the binary or user statement)
- **Version**: exact `terraform -version` / `tofu -version` output
- **Providers**: which providers are required and their version constraints
- **State backend**: where state is stored (local, S3 + DynamoDB, S3 + native lockfile, TF Cloud, GCS, Azure Storage, etc.)
- **Execution path**: local workstation, CI pipeline, HCP Terraform / Terraform Cloud, Atlantis, custom runner
- **Environment criticality**: dev, staging, prod, regulated workload (HIPAA / PCI / FedRAMP)
- **State assumptions**: prod/non-prod isolation, lock enabled, state encryption at rest

The agent expects each bullet to either have an answer or an explicit "assumed because not provided".

### 2. Risk Category Addressed

Tag the primary risk category from the diagnose-first map. Multiple categories are acceptable when a finding spans them. Do not invent new categories — they must match `rules/terraform/patterns.md` 1:1:

- Identity churn — resource address stability
- Secret exposure — credentials, sensitive data
- Blast radius — destructive potential, scope
- CI drift — local ≠ CI plans, unpinned versions
- Compliance gaps — approval, audit trail
- State corruption — lock, backend, drift
- Provider upgrade risk — breaking changes
- Testing blind spots — computed values, mocks
- Provider lifecycle — removal, orphans

### 3. Remediation Chosen & Tradeoffs

Specific. "Convert `count` to `for_each` with map key" — not "fix the iteration". Spell out:

- **What was chosen**: the specific fix
- **What was traded off**: cost of the choice (e.g., "3 additional lines of variable plumbing; requires a `moved` block per existing instance")
- **Why**: the safety or business reason ("for_each with stable keys prevents identity churn if the list is reordered")

### 4. Validation Plan (REQUIRED — never skip)

List the exact commands. Never "run validation" — name each command. This section is non-optional even for read-only reviews; the reader needs to know how to confirm the findings before merging:

- `{terraform|tofu} fmt -check -recursive` — formatting compliance
- `{terraform|tofu} validate` — HCL syntax and version compatibility
- `{terraform|tofu} plan -out=tfplan` — preview changes; review for expected resource behavior; archive the plan artifact
- `tflint --format compact` — best-practices linting
- `trivy config .` — IaC misconfiguration scan (HIGH/CRITICAL filter)
- `checkov -d .` — policy and security scanning

When unsure which commands apply, default to `{terraform|tofu} fmt -check && {terraform|tofu} validate && {terraform|tofu} plan -lock=false`.

### 5. Rollback Notes (REQUIRED for state-mutating changes)

A change is **state-mutating** if it could cause `{terraform|tofu} plan` to show destroys or moves on existing infrastructure. Examples:

- `count` → `for_each` refactor (without `moved` blocks would destroy/recreate)
- Resource rename (without `moved` block would destroy/recreate)
- Adding/removing/changing `moved` blocks
- Changing iteration keys
- Backend migration (S3 → S3+lockfile, local → remote)
- Provider major-version bump that changes computed defaults

For ANY of these, document recovery — never omit:

- **How to undo**: manual steps (e.g., "restore state from backup: `{terraform|tofu} state pull < backup.json`", or "git revert HEAD then `plan` to confirm zero diff")
- **What evidence to keep**: plan artifacts, pre-refactor `state list` output, state backups, git commits for audit trail
- **Recovery from partial apply**: `state mv` commands to swap addresses back to the pre-refactor structure
- **When rollback needed**: conditions to trigger restore ("if apply fails or detected drift", "if plan shows unexpected destroys instead of moves")

For non-state-mutating changes (variable additions, output additions, comment changes, formatting): write `n/a — non-state-mutating change`. Do not skip the section.

> Canonical wording lives in `rules/terraform/patterns.md` (Response Contract section) and `agents/terraform-reviewer.md` (sections §1–§5). If the agent's review is missing a section, treat it as a review defect and request the missing piece before approving.

## Diagnose Before Reviewing

Match the user's situation to a failure category, then route to the matching reference. If the task spans categories, route to all matches. The categories below map 1:1 to `rules/terraform/patterns.md`; do not invent new ones.

| Failure category | Symptoms | Where to look |
|---|---|---|
| **Identity churn** | Resource addresses shift after refactor; `count` index churn; missing `moved` blocks | skill: `terraform-patterns` (count vs for_each, moved blocks) |
| **Secret exposure** | Literal secrets in defaults; `sensitive = true` confused with state exclusion; data-source secrets persisted to state | skill: `terraform-security` (state secret hygiene) |
| **Blast radius** | Oversized stacks; shared prod/non-prod state; unsafe applies without plan review | skill: `terraform-patterns` (module hierarchy) |
| **CI drift** | Local plan ≠ CI plan; apply without reviewed artifact; unpinned providers/modules | skill: `terraform-patterns` (versions section) |
| **Compliance gaps** | Missing policy stage; no approval model; no evidence retention; missing scanner output | skill: `terraform-security` (scanner integration) |
| **Testing blind spots** | Plan-only validation of computed values; set-type indexing in tests; mock/real confusion | skill: `terraform-testing` |
| **State corruption / recovery** | Stuck lock; backend migration; drift reconciliation; orphaned resources | agent: `terraform-build-resolver`; skill: `terraform-patterns` |
| **Provider upgrade risk** | Breaking-change provider bump; unpinned modules; conflicting constraint ranges | skill: `terraform-patterns` (versions section) |
| **Provider lifecycle** | Removing a provider with resources still in state; orphaned resources; `removed` block usage | skill: `terraform-patterns` (provider lifecycle) |

If a review request maps to no category, default to the agent's CRITICAL / HIGH / MEDIUM priorities and run the full diagnostic command set.

## How To Invoke

The user-facing surface is plain English on `.tf`/`.tofu`/`.tfvars` files: "review this terraform module", "audit these IaC changes", "is this safe to apply", "check this for IaC issues". Claude auto-discovers this skill, frames the contract, and the `terraform-reviewer` agent fires. Skills do not call agents directly — the framing is the routing.

If the review surfaces an `init`/`validate`/`plan`/`apply` failure that needs surgical repair (not just findings), hand off to `agent: terraform-build-resolver` after the review block. The reviewer reports; the build-resolver fixes.

If the review needs IaC-class security depth (state secret hygiene, security-group hygiene, scanner suppression rules), the `terraform-security` skill auto-loads alongside this one — both frames are complementary on a "review for security issues" prompt.

## OpenTofu Notes

The review flow is identical for OpenTofu — same Response Contract, same failure categories, same priorities. CLI commands in the Validation Plan should match the user's runtime: write `{terraform|tofu}` when both work; write `tofu` only when an OpenTofu-specific feature is involved (e.g., OT 1.7+ built-in state encryption — covered in `terraform-security`). The default registry differs (`registry.terraform.io` vs `registry.opentofu.org`) but does not affect the review flow. When the runtime is unclear from context, ask once at the top of the review and capture the answer in §1 — Assumptions & Version Floor.

## Anti-Patterns This Review Catches

Quick orientation — what the reviewer agent is most likely to flag, and at what severity. Depth on each pattern lives in the linked skill.

```hcl
# ❌ CRITICAL — literal secret in variable default (skill: terraform-security)
variable "db_password" {
  type    = string
  default = "SuperSecret123!"
}

# ❌ CRITICAL — count over a list with index-based identity (skill: terraform-patterns)
resource "aws_subnet" "this" {
  count      = length(var.subnet_cidrs)
  cidr_block = var.subnet_cidrs[count.index]
  vpc_id     = aws_vpc.this.id
}

# ❌ HIGH — backend declared inside a reusable module (skill: terraform-patterns)
# modules/network/versions.tf:
terraform {
  backend "s3" { ... }   # belongs at composition only
}

# ❌ HIGH — unpinned provider in versions.tf (skill: terraform-patterns)
terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }   # no version constraint
  }
}

# ❌ MEDIUM — 0.0.0.0/0 ingress on SSH (skill: terraform-security)
resource "aws_security_group_rule" "ssh" {
  type        = "ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
```

The reviewer agent's full priority list (CRITICAL state safety / identity stability / blast radius; HIGH version pinning / state hygiene / module signature / module hygiene; MEDIUM provider sync / best practices) lives in `agents/terraform-reviewer.md`. This skill body shows representatives of each tier so the framing is concrete; the agent owns the canonical list.

## Worked Example — Minimal Review Skeleton

When the agent fires, the output should look approximately like this:

```markdown
### 1. Assumptions & Version Floor
- Runtime: terraform 1.11.3 (assumed; not stated)
- Providers: hashicorp/aws ~> 5.71
- State backend: S3 + DynamoDB (assumed; not stated)
- Execution path: local (assumed; not stated)
- Environment: prod (inferred from `environments/prod/`)

### 2. Risk Category Addressed
- Secret exposure (literal `default = "..."` in variable)
- Identity churn (`count` over a list of subnets)

### 3. Remediation Chosen & Tradeoffs
- Move `database_password` to `password_wo` (TF 1.11+, AWS provider 5.71+);
  trades 1 line for state exclusion.
- Convert `count` to `for_each = toset(var.subnets)`; emit `moved` for each
  existing subnet to preserve state addresses.

### 4. Validation Plan
- terraform fmt -check -recursive
- terraform validate
- terraform plan -out=tfplan
- tflint --format compact
- trivy config .
- checkov -d .

### 5. Rollback Notes
- `count` → `for_each` is state-mutating. Backup state with
  `terraform state pull > backup.json` before apply. If plan shows
  destroys instead of moves, halt — `moved` block addresses are wrong;
  fix the keys and re-plan. To undo: `git revert HEAD` then re-plan to
  confirm zero diff.
```

Each section has substance; none is empty; section names are exact.

## Pre-merge Review Checklist

Run through this before marking a review approved. Every row has an explicit pass/fail; do not approve with rows unchecked.

| Check | Command or evidence |
|---|---|
| Formatting clean | `{terraform\|tofu} fmt -check -recursive` returns 0 |
| Syntax valid | `{terraform\|tofu} validate` returns 0 |
| Plan reviewed | `{terraform\|tofu} plan -out=tfplan` reviewed; no unexpected destroys or moves |
| Lint clean | `tflint --format compact` returns 0 OR each rule suppression documented in `.tflint.hcl` |
| Misconfig scan clean | `trivy config .` clean OR each rule suppression documented in `.trivyignore` |
| Policy scan clean | `checkov -d .` clean OR each rule suppression documented in `.checkov.yaml` |
| No literal secrets | No `default = "..."` strings that look like credentials in `.tf`/`.tfvars` |
| Refactor safety | `moved` blocks present for any rename, `count`→`for_each` change, or module restructure |
| Version floor pinned | `versions.tf` declares `required_version` and every entry in `required_providers` |
| Backend at composition only | No `terraform { backend "..." {} }` block inside any reusable module |
| Lock file at composition | `.terraform.lock.hcl` committed at the composition; absent inside reusable modules |
| Response Contract present | All 5 sections present in the review block; `Validation Plan` and `Rollback Notes` non-empty |

## Cross-References

- **Patterns and idioms**: skill: `terraform-patterns`
- **IaC-class security checklist**: skill: `terraform-security`
- **Test framework choice / assertions**: skill: `terraform-testing`
- **Reviewer agent (CRITICAL/HIGH/MEDIUM priorities, line-by-line findings)**: agent: `terraform-reviewer`
- **Build / init / validate / plan / apply error repair**: agent: `terraform-build-resolver`
- **Rules summary surfaces**: `rules/terraform/patterns.md` (Response Contract, diagnose-first map), `rules/terraform/security.md` (IaC summary), `rules/terraform/testing.md` (test summary)

**Remember**: diagnose first, frame the Response Contract, route via the failure-category map, defer line-by-line findings to the `terraform-reviewer` agent, and never approve a state-mutating change without explicit Rollback Notes.

---

> Adapted from terraform-skill and terraform-best-practices by Anton Babenko (Apache-2.0).
