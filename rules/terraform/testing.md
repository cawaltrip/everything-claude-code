---
paths:
  - "**/*.tf"
  - "**/*.tofu"
  - "**/*.tfvars"
  - "**/*.tfvars.json"
  - "**/.terraform.lock.hcl"
---
# Terraform/OpenTofu Testing

> This file extends [common/testing.md](../common/testing.md) with Terraform/OpenTofu specific content.

## Framework

Native `terraform test` (TF 1.6+) / `tofu test` (OT 1.6+) is the default for new tests. Reach for **Terratest** only when Go expertise exists or when integration scope exceeds native capability.

## `command = plan` vs `command = apply`

- `command = plan` — input-derived values only; fast and cheap.
- `command = apply` — REQUIRED for **computed values** (ARNs, generated names) and **set-type nested blocks** (S3 encryption rules, lifecycle transitions, IAM policy statements).

Set-type blocks cannot be indexed with `[0]`; use `for` expressions or materialize via `command = apply`.

## Mock Providers (TF 1.7+ / OT 1.7+)

Prefer mocks for unit-shape tests to avoid real-cloud cost. Reserve real-cloud runs for final integration on `main` or scheduled workflows.

## Coverage

There is no native TF coverage tool. "Coverage" = whether each module path (input combination) has a test. The 80% common rule applies to *paths covered*, not to a tool-reported percentage.

## Reference

See skill: `terraform-testing` for the test-framework decision matrix, mock-provider patterns, and TDD workflow adapted for IaC.
