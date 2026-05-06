---
name: terraform-mcp
description: Live Terraform/OpenTofu provider, resource, and module schema lookup via the official HashiCorp Terraform MCP server. Use when the user has the `terraform` MCP server configured (mcp__terraform__* tools available) and is writing or reviewing `*.tftest.hcl` test assertions, validating resource block-types (set vs list vs computed), looking up the latest provider/module versions, or discovering registry modules. Always load on test-writing tasks that touch any non-trivial resource schema — recall is unreliable for set-vs-list distinctions and the cost of a single MCP query is far less than a wrong assertion. Activates on prompts like "write a test for this resource", "what attributes does this resource have", "look up the latest aws provider", or "find a module for X".
origin: ECC
---

# Terraform/OpenTofu MCP Skill

Live provider, resource, and module schema lookup via the official HashiCorp Terraform MCP server. Activates when `mcp__terraform__*` tools are available. Live > static — provider attributes, set-vs-list block types, and registry module signatures change frequently; this skill lets you read the truth instead of guessing from possibly-stale markdown.

## When to Use

- Validating a resource's block-type structure before writing a `*.tftest.hcl` assertion (set vs list vs computed)
- Looking up the latest stable provider or module version before pinning
- Discovering registry modules by topic, comparing input contracts
- Confirming an attribute name or type before referencing it in a resource block
- Running a one-shot "what's new in this provider major" check before a version bump

## Setup

The HashiCorp Terraform MCP server ships as a Docker image (`hashicorp/terraform-mcp-server`), not an npm package. Docker must be installed and running on every endpoint that uses the server — Claude Code spawns the container per session via stdio.

### CLI install (recommended)

```bash
claude mcp add terraform -s user -t stdio -- docker run -i --rm hashicorp/terraform-mcp-server:0.5.2
```

Drop `-s user` and run from a repo root if you want the server scoped to that project (writes to `.mcp.json`).

### Hand-edit equivalent

Add to your `~/.claude.json` `mcpServers` block (or `.mcp.json` at the project root):

```json
{
  "mcpServers": {
    "terraform": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "hashicorp/terraform-mcp-server:0.5.2"]
    }
  }
}
```

For HCP Terraform / Terraform Enterprise tools (workspace operations, plan/apply logs, private registry), pass credentials:

```json
{
  "mcpServers": {
    "terraform": {
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "-e", "TFE_TOKEN",
        "-e", "TFE_ADDRESS",
        "hashicorp/terraform-mcp-server:0.5.2"
      ],
      "env": {
        "TFE_TOKEN": "<token>",
        "TFE_ADDRESS": "https://app.terraform.io"
      }
    }
  }
}
```

After restart, verify the server is connected with `claude mcp list` or `/mcp` — tools surface prefixed `mcp__terraform__`.

> Pin the image tag (`:0.5.2`) — `hashicorp/terraform-mcp-server:latest` floats and will silently change behavior across releases. The official HashiCorp image is the recommended default; community forks exist but should not be used unless you have a specific reason to switch.

## Tools

### Public registry (no auth)

| Tool | Use For |
|---|---|
| `mcp__terraform__search_providers` | Find a provider's resources/data sources by name and namespace |
| `mcp__terraform__get_provider_details` | Pull the full schema for a specific resource (block-type, attributes, computed-vs-input, latest version) |
| `mcp__terraform__get_provider_capabilities` | List a provider's overall capability surface (toolsets, namespaces) |
| `mcp__terraform__search_modules` | Discover community/registry modules by topic |
| `mcp__terraform__get_module_details` | Inspect a module's input/output contract and latest version |
| `mcp__terraform__search_policies` | Find Sentinel/policy modules by topic |
| `mcp__terraform__get_policy_details` | Pull a policy module's signature and version |

Version info (latest provider version, latest module version) is surfaced inline in the corresponding `get_*_details` response — there is no separate `latest_*` tool.

### HCP Terraform / Terraform Enterprise (requires `TFE_TOKEN`)

When the server starts with `TFE_TOKEN` set, an additional ~25 tools surface for workspace, run, plan, apply, organization, project, private-registry, policy-set, and variable-set operations. Notable examples: `mcp__terraform__list_workspaces`, `mcp__terraform__get_run_details`, `mcp__terraform__get_plan_logs`, `mcp__terraform__search_private_modules`. The full list lives in [hashicorp/terraform-mcp-server `pkg/tools/tfe/`](https://github.com/hashicorp/terraform-mcp-server/tree/main/pkg/tools/tfe). Use these only with explicit user intent — they read and mutate live HCP/TFE state.

## Workflow: Validate Before Asserting

Before writing a `*.tftest.hcl` assertion against a nested block, confirm the block-type from the live schema. The set-vs-list distinction is the most common source of LLM-generated test bugs and the most durable thing to look up rather than recall.

```text
1. mcp__terraform__search_providers({
     provider_name: "aws",
     provider_namespace: "hashicorp",
     service_slug: "s3_bucket_server_side_encryption_configuration",
     provider_document_type: "resources"
   })
2. mcp__terraform__get_provider_details({ provider_doc_id: "<id from step 1>" })
3. Read the schema. Note: is `rule` a `set` or a `list`? Is the inner block a list-of-1?
4. Write the assertion. Use `for` expressions for sets; `[0]` only for list-of-1.
```

## Workflow: Confirm Before Pinning

Before bumping a provider or module version constraint in `versions.tf`, confirm the latest stable version and surface known breaking changes. Static markdown ages on every provider release; the MCP server is the durable source of truth.

```text
1. mcp__terraform__get_provider_details({ provider_doc_id: "<id>" })
   — the response includes the latest version alongside the schema
2. Compare against the current `versions.tf` constraint. Is the bump a major, minor, or patch?
3. For majors, flag breaking-change risk to the user before editing — pull provider release notes, scope the migration, and decide whether to pin to the previous major.
```

For modules, use `mcp__terraform__get_module_details` — same shape, same logic, version surfaces in the response. Read the input/output contract while you're there, since a major-version bump is also when input signatures most commonly drift.

## Runtime Divergence

The HashiCorp MCP server parses `.tf` and `.tofu` files identically. Where it diverges from OpenTofu's stance is the *registry endpoint* — the server queries `registry.terraform.io` by default. For OpenTofu-only modules hosted on `registry.opentofu.org`, you'll get a miss; check the OT registry directly for those. Resource and provider schemas are identical between runtimes through 1.x.

> OpenTofu-only features (state encryption 1.7+, provider iteration 1.7+) won't appear in `registry.terraform.io` schema responses but are documented in OpenTofu's own docs. The MCP server is authoritative for shared TF/OT schema; OpenTofu-only features need the OT documentation directly.

## Cross-References

- [`skills/terraform-testing/SKILL.md`](../terraform-testing/SKILL.md) — primary consumer; uses MCP for schema validation in tests
- [`skills/terraform-patterns/SKILL.md`](../terraform-patterns/SKILL.md) — version-management section; this skill replaces the snapshot-in-markdown approach with live lookup
- [`agents/terraform-reviewer.md`](../../agents/terraform-reviewer.md) — review tasks that need to confirm schema or version assumptions
- [`agents/terraform-build-resolver.md`](../../agents/terraform-build-resolver.md) — debugging schema-target errors during init/validate/plan

---

> Uses the official HashiCorp Terraform MCP server (Mozilla Public License 2.0). See [hashicorp/terraform-mcp-server](https://github.com/hashicorp/terraform-mcp-server) for source and license.
