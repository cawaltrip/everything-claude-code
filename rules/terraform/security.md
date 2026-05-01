---
paths:
  - "**/*.tf"
  - "**/*.tofu"
  - "**/*.tfvars"
  - "**/*.tfvars.json"
  - "**/.terraform.lock.hcl"
---
# Terraform/OpenTofu Security

> This file extends [common/security.md](../common/security.md) with Terraform/OpenTofu specific content.

## IaC Security Checklist

Before any `apply` (or merging a TF/OT change to main):

- [ ] No secrets in `*.tf`, `*.tfvars`, or default values
- [ ] No `0.0.0.0/0` ingress on `aws_security_group_*` (or equivalent)
- [ ] No use of default VPC / default network
- [ ] Encryption at rest enabled on all data resources (S3, RDS, EBS, etc.)
- [ ] All providers and modules version-pinned
- [ ] Remote backend configured (no local state for shared infra)
- [ ] Sensitive variables marked `sensitive = true` AND, on TF 1.11+ / OT 1.8+, secret-bearing arguments use `write_only` / `*_wo`
- [ ] No inline `ingress`/`egress` blocks in `aws_security_group` (use `aws_vpc_security_group_*_rule` resources, AWS provider v5+)

## Secret Management for IaC

Secrets come from runtime providers (AWS Secrets Manager, SSM Parameter Store, Vault, etc.), never from `.tfvars`.

`sensitive = true` masks the value in CLI display only — the value still lives in state. Use `write_only` arguments on TF 1.11+ / OT 1.8+ when the provider supports them; otherwise keep secret material out of TF entirely via runtime data sources.

## Security Scanners

Canonical scanner set:

```bash
tflint --recursive
trivy config .
checkov -d .
```

These run via the Stop hook (see [hooks.md](hooks.md)). **Do not invoke them mid-implementation** — running scanners on in-progress code creates a churn loop.

## Reference

See skill: `terraform-security` for the full IaC-class security checklist and remediation patterns.
