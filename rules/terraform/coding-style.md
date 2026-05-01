---
paths:
  - "**/*.tf"
  - "**/*.tofu"
  - "**/*.tfvars"
  - "**/*.tfvars.json"
  - "**/.terraform.lock.hcl"
---
# Terraform/OpenTofu Coding Style

> This file extends [common/coding-style.md](../common/coding-style.md) with Terraform/OpenTofu specific content.

## Formatting

`terraform fmt` (or `tofu fmt`) is mandatory — no style debates. Auto-applied via PostToolUse hook (see [hooks.md](hooks.md)). Both binaries parse `.tf` and `.tofu` files; either produces identical output.

## File Organization

Standard files in every module:

- `main.tf` — resources, data sources, locals
- `variables.tf` — typed inputs with `description`
- `outputs.tf` — typed outputs with `description`
- `versions.tf` — `required_version` + `required_providers`

`terraform.tfvars` belongs only at the composition layer, never inside reusable modules.

## Naming

- Use descriptive resource names: `aws_instance.web_server`, not `aws_instance.main`.
- Reserve `this` for genuine singletons (a module that creates exactly one of a thing).
- Prefix variables with context: `vpc_cidr_block`, not `cidr`.
- Standard file names match exactly — never `vars.tf` or `out.tf`.

## Block Ordering

**Resource blocks**: `count` / `for_each` first → arguments → `tags` → `depends_on` → `lifecycle`.

**Variable blocks**: `description` → `type` → `default` → `validation` → `nullable` → `sensitive`.

## Error Handling

Terraform/OpenTofu errors are state-mismatch shaped, not exception-shaped:

- Use `validation` blocks for input-time guards.
- Use `lifecycle.precondition` / `postcondition` (1.2+) for runtime guards.
- Reserve `try()` for data-source-shape variations — never to silence errors.

## Reference

See skill: `terraform-patterns` for comprehensive TF/OT idioms and patterns.
