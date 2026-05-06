---
name: terraform-testing
description: Terraform/OpenTofu testing patterns covering native `terraform test`/`tofu test` (1.6+), mock providers (1.7+), Terratest decision criteria, plan-vs-apply mode rules, set-type assertion handling, and TDD adapted for IaC. Use when writing or reviewing `*.tftest.hcl` files, designing IaC test suites, choosing between native tests and Terratest, or any task involving HCL test assertions against resource attributes. Pairs with skill: terraform-mcp when the HashiCorp Terraform MCP server is configured — load both for schema-sensitive test work.
origin: ECC
---

# Terraform/OpenTofu Testing

Testing patterns for Terraform and OpenTofu modules — native `terraform test`/`tofu test` (1.6+), mock providers (1.7+), Terratest decision criteria, and TDD adapted for IaC realities. Static analysis first, real-cloud last.

## When to Use

- Writing or refactoring `*.tftest.hcl` files (`terraform test` / `tofu test`)
- Designing a test suite for a new or existing Terraform/OpenTofu module
- Deciding between native tests, mock providers (1.7+), and Terratest
- Adding test coverage to a module before a state-mutating refactor
- Choosing `command = plan` vs `command = apply` for a given assertion
- Writing assertions against set-type nested blocks (S3 encryption rules, lifecycle transitions, IAM policy statements)
- Scoping integration vs unit tests against a real-cloud budget

## How It Works

This skill covers seven areas: a static-analysis-first pipeline (always free, always fast); a decision matrix that picks among native tests, mock providers, and Terratest based on team capability and cost tolerance; the canonical `command = plan` vs `command = apply` rule with the set-type-indexing trap and worked solutions; mock-provider patterns for cost-free unit tests (TF 1.7+/OT 1.7+); a Terratest profile that names when Go-based integration is the right call (and when it isn't); a TDD-for-IaC workflow adapted to the realities of plan/apply cycles; and an LLM-mistake checklist mined from real-world test bugs. OpenTofu divergence is inlined as `{terraform|tofu}` notation throughout. When the HashiCorp Terraform MCP server is configured, the sibling `skills/terraform-mcp` skill auto-activates and supplies live schema lookup; without MCP, the no-MCP heuristics in the Cross-References section keep schema-target accuracy high.

## Static Analysis First

Always cheapest, always fastest. Run before any test invocation.

```bash
{terraform|tofu} fmt -check -recursive
{terraform|tofu} validate
tflint --format compact
trivy config .   # optional, security-focused
```

Hook gating, scanner deferral, and the per-project override mechanism live in [`rules/terraform/hooks.md`](../../rules/terraform/hooks.md). The locked default defers `tflint`/`trivy`/`checkov` to the Stop hook so the inner-loop test cycle stays fast — don't recommend a different policy in test workflows.

## Decision Matrix

| Situation | Approach | Tools | Cost | Floor |
|---|---|---|---|---|
| Quick syntax check | Static analysis | `{terraform\|tofu} fmt -check`, `validate` | Free | Any version |
| Pre-commit validation | Static + lint + scan | `validate`, `tflint`, `trivy`, `checkov` | Free | Any version |
| Module unit tests, HCL-only team | Native test (mocked) | `{terraform\|tofu} test` + `mock_provider` | Free | TF `~> 1.7` / OT `~> 1.7` |
| Module unit tests pre-1.7 | Native test (real cloud, scoped) | `{terraform\|tofu} test` (no mocks) | Low | TF `~> 1.6` / OT `~> 1.6` |
| Cross-module integration, Go team | Terratest | `terratest` + `defer terraform.Destroy` | Low–Med | Any version |
| Multi-cloud or exotic provider behavior | Terratest + real infra | Terratest, account isolation | Med–High | Any version |
| Policy / compliance gates | Policy as code | OPA, Sentinel, conftest | Free | Any version |

**Reading the table**: Pick the leftmost row that matches your situation. The version-floor column is non-negotiable — if you can't satisfy the floor, drop to the next row.

## Native `terraform test` / `tofu test`

Native test framework lives in `tests/` directory under the module root. Files end in `.tftest.hcl`. Each file holds one or more `run` blocks; each `run` chooses `command = plan` or `command = apply` and lists `assert` blocks.

### Test File Layout

```hcl
# tests/s3_bucket.tftest.hcl
run "create_bucket" {
  command = apply

  assert {
    condition     = aws_s3_bucket.this.bucket != ""
    error_message = "S3 bucket name must be set"
  }
}

run "verify_encryption" {
  command = apply  # `rule` is a set; use `one(...)` to extract the singleton

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Bucket must use AES256 encryption"
  }
}
```

Test discovery: `{terraform|tofu} test` finds `*.tftest.hcl` files under `tests/` relative to the module root. Use `-filter=<path>` to scope to a specific file.

### `command = plan` vs `command = apply`

The single most common LLM-generated test bug. Get this wrong once and the user has to hand-correct.

| Goal | Mode | Why |
|---|---|---|
| Input-derived attribute (e.g. bucket name from `var.bucket`) | `plan` | Value known before refresh |
| Variable default / `validation` block exercise | `plan` | Fast, no resource creation |
| Computed attribute (ARN, generated name, cloud-assigned ID) | `apply` | Only known after provider round-trip |
| Set-type nested block (S3 encryption rules, lifecycle transitions, IAM policy statements) | `apply` | Materializes the set so `for` expressions resolve |
| Real behavior or mocked-provider responses | `apply` | Runs the create path |

**Asserting a computed value in `plan` mode** → `Condition expression could not be evaluated at this time`. Fix: switch the `run` block to `command = apply`, or assert a different attribute that is known at plan.

### Set-type indexing trap

```hcl
# WRONG — sets cannot be indexed
condition = aws_s3_bucket_server_side_encryption_configuration.this.rule[0].bucket_key_enabled == true
# Error: Cannot index a set value

# Solution 1 — for-expression with apply mode
run "test_encryption" {
  command = apply
  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_server_side_encryption_configuration.this.rule :
      alltrue([
        for cfg in rule.apply_server_side_encryption_by_default :
        cfg.sse_algorithm == "AES256"
      ])
    ])
    error_message = "Default encryption should be AES256"
  }
}

# Solution 2 — `one(...)` when the set is known to have exactly one member
run "verify_encryption" {
  command = apply
  assert {
    condition = one(
      aws_s3_bucket_server_side_encryption_configuration.this.rule
    ).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Bucket must use AES256 encryption"
  }
}
```

Block-type distinctions to verify against the real schema:

- **set** — unordered, cannot index with `[0]`
- **list** — ordered, indexable
- **MaxItems=1 nested block** — list-of-1; `[0]` is safe
- **computed** attribute — only known after apply

Common AWS set-vs-list patterns:

| Resource | Block | Type | Indexing |
|---|---|---|---|
| `aws_s3_bucket_server_side_encryption_configuration` | `rule` | **set** | use `for` or `one(...)` |
| `aws_s3_bucket_lifecycle_configuration` | `transition` | **set** | use `for` or `one(...)` |
| `aws_s3_bucket_lifecycle_configuration` | `noncurrent_version_expiration` | **list-of-1** | `[0]` is safe |

### Worked example: S3 bucket

```hcl
# tests/unit/s3_bucket.tftest.hcl

mock_provider "aws" {}  # Zero cost — entire AWS provider mocked

# Test 1: input validation (fast, plan mode)
run "validate_bucket_name" {
  command = plan

  variables {
    bucket = "my-test-bucket"
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "my-test-bucket"
    error_message = "Bucket name should match input"
  }
}

# Test 2: default encryption (apply mode for set-type access)
run "verify_default_encryption" {
  command = apply

  variables {
    bucket = "encrypted-bucket"
  }

  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_server_side_encryption_configuration.this.rule :
      alltrue([
        for cfg in rule.apply_server_side_encryption_by_default :
        cfg.sse_algorithm == "AES256"
      ])
    ])
    error_message = "Default encryption should be AES256"
  }

  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_server_side_encryption_configuration.this.rule :
      rule.bucket_key_enabled == true
    ])
    error_message = "Bucket key should be enabled"
  }
}

# Test 3: computed values (apply mode required)
run "verify_generated_name" {
  command = apply

  variables {
    bucket_prefix = "test-"
  }

  assert {
    condition     = startswith(aws_s3_bucket.this.bucket, "test-")
    error_message = "Generated bucket name should have prefix"
  }
}
```

For schema validation against real provider attributes when the HashiCorp Terraform MCP server is configured, see [`skills/terraform-mcp/SKILL.md`](../terraform-mcp/SKILL.md). Without MCP, see the four-heuristic block in this skill's Cross-References section.

## Mock Providers (TF `~> 1.7` / OT `~> 1.7`)

Mock the entire provider for cost-free unit tests. Override per-resource only when a default doesn't fit the test.

```hcl
# tests/unit/s3_bucket.tftest.hcl
mock_provider "aws" {}  # Zero cost; entire AWS provider mocked

run "validate_bucket_name" {
  command = plan
  variables { bucket = "my-test-bucket" }
  assert {
    condition     = aws_s3_bucket.this.bucket == "my-test-bucket"
    error_message = "Bucket name should match input"
  }
}

# Per-resource overrides when a default is wrong for the test
mock_provider "aws" {
  mock_resource "aws_instance" {
    defaults = {
      id  = "i-mock123"
      arn = "arn:aws:ec2:us-east-1:123456789:instance/i-mock123"
    }
  }
}
```

Mocks validate module *logic*, not provider *behavior*. Use Terratest against real cloud for the integration coverage tier.

## Terratest

Go-based integration testing. Use when the team has Go expertise OR the test scope exceeds native capability — multi-cloud, real provider behavior, complex orchestration. Don't reach for Terratest when native tests suffice; the cost gap is real.

### When to use

- Team already has Go expertise on the IaC side
- Test scope spans more than one module (full composition)
- Need real-cloud coverage for provider behavior the mocks can't reproduce
- Multi-cloud orchestration or exotic provider matrices

### When NOT to use

- HCL-only team — the Go learning curve outweighs the integration depth
- Unit-shape testing of module logic — native tests with mocks are cheaper and faster
- Cost-sensitive CI where every commit would otherwise fan out into real-cloud applies

### Example

```go
package test

import (
  "testing"
  "github.com/gruntwork-io/terratest/modules/random"
  "github.com/gruntwork-io/terratest/modules/terraform"
  "github.com/stretchr/testify/assert"
)

func TestS3Module(t *testing.T) {
  t.Parallel() // REQUIRED for parallel execution

  options := &terraform.Options{
    TerraformDir: "../examples/complete",
    Vars: map[string]interface{}{
      "bucket_name": "test-bucket-" + random.UniqueId(),
      "tags": map[string]string{
        "Environment": "test",
        "TTL":         "2h", // Auto-cleanup signal for sweep job
      },
    },
  }

  defer terraform.Destroy(t, options) // ALWAYS

  terraform.InitAndApply(t, options)
  bucket := terraform.Output(t, options, "bucket_name")
  assert.NotEmpty(t, bucket)
}
```

### Cost-control checklist

- `t.Parallel()` always — enables parallel execution; without it suite runtime balloons
- `defer terraform.Destroy(t, options)` always — guarantees cleanup even on test failure
- Unique identifiers (`random.UniqueId()`) — prevent resource-name collisions across parallel runs
- TTL tags (`TTL: "2h"`) — cooperative signal for an out-of-band sweep job to garbage-collect orphans
- Account isolation — run integration tests in a dedicated AWS/GCP/Azure account so a missed cleanup never bills against production budget

## TDD for IaC

The classic RED-GREEN-REFACTOR doesn't translate cleanly to infrastructure — there's no "minimal compile" step in HCL, and a failing `plan` is not the same kind of failure signal as a failing unit test. Adapt to RED-GREEN-REFACTOR-VALIDATE:

1. **RED**: Write a `*.tftest.hcl` `run` block that asserts the desired *outcome*. Run `{terraform|tofu} test` — confirm the assertion fails (or the resource is missing entirely).
2. **GREEN**: Add the minimum HCL — variable, resource, or `locals` value — to satisfy the assertion. Run the test again; expect it to pass.
3. **REFACTOR**: Clean up. If you needed to introduce a `moved` block, the rollback discipline from `agents/terraform-reviewer.md` §5 applies.
4. **VALIDATE**: Run static analysis (`fmt -check`, `validate`, `tflint`) and run the full test file. Idempotency check: `{terraform|tofu} plan -detailed-exitcode` after any apply-mode test should exit `0` (no diff). Exit `0` (no diff) is the only acceptable outcome — exit `2` means a follow-up apply would change something, which is a regression.

Cost-aware corollary: prefer `mock_provider` (TF `~> 1.7`/OT `~> 1.7`) for the inner loop. Real-cloud Terratest belongs on `main` or scheduled CI, not on every commit.

## LLM Mistake Checklist — Testing

Common mistakes when generating test code (verify before committing):

- ❌ Asserting computed values (ARNs, generated names, cloud-assigned IDs) in `command = plan` — must use `command = apply`
- ❌ Indexing set-type nested blocks with `[0]` — sets are unordered; use `for` expressions or `one(...)`
- ❌ Treating mocked-provider tests as integration coverage — mocks validate logic only, not provider behavior
- ❌ Forgetting to exercise `validation` blocks with invalid inputs — only happy-path coverage
- ❌ Skipping idempotency check (`plan -detailed-exitcode` after apply) — most common regression detector
- ❌ Asserting on Terraform/HCL syntax instead of module behavior — `validate` already covers syntax
- ❌ Running expensive real-cloud Terratest on every commit instead of gating to `main`/scheduled
- ❌ Omitting cleanup, leaving orphaned resources billed against the test account
- ❌ Hardcoding cloud IDs / account numbers / regions in test variables — parameterize and randomize

## Cross-References

- [`skills/terraform-patterns/SKILL.md`](../terraform-patterns/SKILL.md) — module hierarchy, naming, block ordering, identity stability
- [`skills/terraform-mcp/SKILL.md`](../terraform-mcp/SKILL.md) — live provider/module schema lookup when the HashiCorp Terraform MCP server is configured
- [`agents/terraform-reviewer.md`](../../agents/terraform-reviewer.md) — review tasks (Response Contract §1-§5)
- [`agents/terraform-build-resolver.md`](../../agents/terraform-build-resolver.md) — failed test runs, init/validate/plan errors
- [`rules/terraform/testing.md`](../../rules/terraform/testing.md) — summary surface this skill expands
- [`rules/terraform/hooks.md`](../../rules/terraform/hooks.md) — Stop-hook scanner gating policy

### When MCP isn't available

The testing skill produces correct output without MCP. The internalized rules:

1. **Default to `command = apply`** for any nested-block assertion. The runtime cost is small; the bug-prevention payoff is large.
2. **Use `for` expressions** for any block that *might* be a set. Lists tolerate `for` expressions too — `for` is always safe; `[0]` is sometimes wrong.
3. **Cross-check schema by reading the resource's HCL definition** in the module under test. The module author already had to know the schema to write the resource block.
4. **When uncertain, write the test in `apply` mode and let the failure tell you the schema** — `terraform test` errors include the path that failed to evaluate.

These four heuristics catch ~95% of schema-target bugs without MCP.

---

> Adapted from terraform-skill (Apache-2.0) by Anton Babenko. Native test patterns and the LLM mistake checklist draw on `references/testing-frameworks.md` from that skill.
