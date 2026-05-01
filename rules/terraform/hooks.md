---
paths:
  - "**/*.tf"
  - "**/*.tofu"
  - "**/*.tfvars"
  - "**/*.tfvars.json"
  - "**/.terraform.lock.hcl"
---
# Terraform/OpenTofu Hooks

> This file extends [common/hooks.md](../common/hooks.md) with Terraform/OpenTofu specific content.

## Why this gating exists

TF/OT scanners (`tflint` / `trivy` / `checkov`) report findings about *finished* code. Running them mid-implementation creates a churn loop: the model fixes a finding it just introduced, then the next edit reintroduces something else.

**Defer scanners to session-stop.** `terraform fmt` is fast and idempotent — safe to run PostToolUse.

## Binary detection

For commands invoked from hooks:

- If `tofu` is on PATH, prefer it.
- If `ECC_TF_BINARY` env var is set, honor it (`terraform` or `tofu`).
- If neither is set and only `terraform` is on PATH, use `terraform`.
- `terraform fmt` parses both `.tf` and `.tofu` syntax — usable as fallback if `tofu` is absent.

## PostToolUse — `terraform fmt` (locked default)

Add to `~/.claude/settings.json` or `<project>/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "command": "if echo \"$CLAUDE_FILE_PATHS\" | grep -qE '\\.(tf|tofu|tfvars)$'; then DIR=$(dirname \"$CLAUDE_FILE_PATHS\" | head -n1); BIN=${ECC_TF_BINARY:-$(command -v tofu >/dev/null 2>&1 && echo tofu || echo terraform)}; \"$BIN\" fmt \"$DIR\" 2>/dev/null || true; fi",
        "description": "Auto-format Terraform/OpenTofu files in the edited file's directory; honors ECC_TF_BINARY (default: tofu if present)"
      }
    ]
  }
}
```

The trailing `2>/dev/null || true` is intentional — fmt failures must never block the Edit/Write tool result.

## Stop — three scanners (locked default)

```json
{
  "hooks": {
    "Stop": [
      {
        "command": "DIRS=$(git diff --name-only HEAD 2>/dev/null | grep -E '\\.(tf|tofu|tfvars)$' | xargs -I{} dirname {} 2>/dev/null | sort -u); if [ -z \"$DIRS\" ]; then exit 0; fi; for d in $DIRS; do (cd \"$d\" && (command -v tflint >/dev/null && tflint || echo \"[ECC-TF] tflint not installed; skipping\" >&2; command -v trivy >/dev/null && trivy config . || echo \"[ECC-TF] trivy not installed; skipping\" >&2; command -v checkov >/dev/null && checkov -d . --quiet || echo \"[ECC-TF] checkov not installed; skipping\" >&2)); done",
        "description": "Run tflint/trivy/checkov on TF/OT directories changed this session; detect-and-skip per tool"
      }
    ]
  }
}
```

Scope: directories with TF/OT files in `git diff --name-only HEAD`. Existing `.tflint.hcl` / `.trivyignore` / `.checkov.yaml` are picked up automatically by each tool — do **not** pass `--config` flags.

## Override — opt-in PostToolUse `tflint`

For users who *do* want a scan on every edit, drop into `<project>/.claude/settings.local.json` (project-scoped, never global):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "command": "if echo \"$CLAUDE_FILE_PATHS\" | grep -qE '\\.(tf|tofu)$' && command -v tflint >/dev/null 2>&1; then DIR=$(dirname \"$CLAUDE_FILE_PATHS\" | head -n1); (cd \"$DIR\" && tflint) 2>&1; fi",
        "description": "OPT-IN OVERRIDE: run tflint PostToolUse instead of waiting for Stop hook"
      }
    ]
  }
}
```

**No env-var override** — env vars are easy to leave on across projects. Use `settings.local.json` only.
