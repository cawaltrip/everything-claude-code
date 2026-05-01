---
paths:
  - "**/*.tf"
  - "**/*.tofu"
  - "**/*.tfvars"
  - "**/*.tfvars.json"
  - "**/.terraform.lock.hcl"
---
# Terraform/OpenTofu Patterns

> This file extends [common/patterns.md](../common/patterns.md) with Terraform/OpenTofu specific content.

## Module Hierarchy

Three layers, smallest to largest:

1. **Resource module** — single logical group (a VPC + its subnets, a security group + its rules).
2. **Infrastructure module** — collection of resource modules for a purpose, scoped to one region/account.
3. **Composition** — complete infrastructure spanning multiple regions/accounts.

Flow: resource → resource module → infrastructure module → composition. See skill: `terraform-patterns` for the full taxonomy and worked examples.

## Response Contract

Every Terraform/OpenTofu task response MUST include:

1. **Assumptions & version floor** — runtime (`terraform` or `tofu`), exact version, providers, state backend, execution path (local / CI / Cloud / Atlantis), environment criticality. State assumptions explicitly when the user did not provide them.
2. **Risk category addressed** — one or more of: identity churn, secret exposure, blast radius, CI drift, compliance gaps, state corruption, provider upgrade risk, testing blind spots.
3. **Chosen remediation & tradeoffs** — what was chosen, what was traded off, why.
4. **Validation plan** — exact commands (`fmt -check`, `validate`, `plan -out`, policy check) tailored to runtime and risk tier.
5. **Rollback notes** — for any destructive or state-mutating change: how to undo, what evidence to keep.

Never recommend direct production apply without a reviewed plan artifact and approval.

## Diagnose Before You Generate

Match the user's situation to a failure category, then load the matching reference. If the task spans categories, load all matches.

| Failure category | Symptoms | Primary references |
|------------------|----------|--------------------|
| **Identity churn** | Resource addresses shift after refactor, `count` index churn, missing `moved` blocks | skill: `terraform-patterns` |
| **Secret exposure** | Secrets in defaults, state, logs, CI artifacts | skill: `terraform-security` |
| **Blast radius** | Oversized stacks, shared prod/non-prod state, unsafe applies | skill: `terraform-patterns` |
| **CI drift** | Local plan ≠ CI plan, apply without reviewed artifact, unpinned versions | skill: `terraform-patterns` (versions section) |
| **Compliance gaps** | Missing policy stage, no approval model, no evidence retention | skill: `terraform-security` |
| **Testing blind spots** | Plan-only validation of computed values, set-type indexing, mock/real confusion | skill: `terraform-testing` |
| **State corruption / recovery** | Stuck lock, backend migration, drift reconciliation | agent: `terraform-build-resolver`; skill: `terraform-patterns` |
| **Provider upgrade risk** | Breaking-change provider bump, unpinned modules | skill: `terraform-patterns` (versions section) |
| **Provider lifecycle** | Removing a provider with resources still in state, orphaned resources, `removed` block usage | skill: `terraform-patterns` |

## Block Ordering (summary)

**Resources**: `count`/`for_each` first → arguments → `tags` → `depends_on` → `lifecycle`.

**Variables**: `description` → `type` → `default` → `validation` → `nullable` → `sensitive`.

See skill: `terraform-patterns` for examples and the full rationale.

## Count vs For_Each (summary)

| Scenario | Use | Why |
|---|---|---|
| Boolean toggle (create / don't) | `count = condition ? 1 : 0` | Optional singleton |
| Items may reorder or be removed | `for_each = toset(list)` | Stable resource addresses |
| Reference by key | `for_each = map` | Named access |

**Never** use list index as long-lived identity — removing a middle element reshuffles every address after it. See skill: `terraform-patterns` for the migration playbook with `moved` blocks.

## OpenTofu Divergence

Through 1.x the languages are ~95% identical. Notable divergences:

- **Binaries**: `terraform` (TF) vs `tofu` (OT). Both parse `.tf` and `.tofu`.
- **Default registry**: `registry.terraform.io` vs `registry.opentofu.org`.
- **OT-only features**: built-in state encryption (1.7+), earlier `removed` block availability, provider iteration.

When examples show a CLI command, prefer pointing at the user's runtime; if unknown, ask. See skill: `terraform-patterns` for the full divergence table.

## Reference

See skill: `terraform-patterns` for comprehensive TF/OT idioms and patterns.

> Adapted from terraform-skill and terraform-best-practices by Anton Babenko (Apache-2.0).
