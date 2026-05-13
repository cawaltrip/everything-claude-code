---
name: opentofu-mcp
description: Live OpenTofu provider, resource, module, and data-source schema lookup via the official OpenTofu MCP server. Use when the user has the `opentofu` MCP server configured (mcp__opentofu__* tools available) and is writing or reviewing `*.tftest.hcl` test assertions against `.tofu` (or `.tf`) files, validating resource block-types (set vs list vs computed), looking up the latest provider/module versions from `registry.opentofu.org`, or discovering OpenTofu registry modules — including OpenTofu-only features (state encryption 1.7+, provider iteration 1.7+) that the HashiCorp Terraform MCP server cannot surface. Always load on test-writing tasks that touch any non-trivial resource schema — recall is unreliable for set-vs-list distinctions and the cost of a single MCP query is far less than a wrong assertion. Activates on prompts like "write a test for this OpenTofu resource", "what attributes does this resource have on the OpenTofu registry", "look up the latest aws provider on registry.opentofu.org", or "find an OpenTofu module for X".
origin: ECC
---

# OpenTofu MCP Skill

Live provider, resource, module, and data-source schema lookup via the official OpenTofu MCP server. Activates when `mcp__opentofu__*` tools are available. Live > static — provider attributes, set-vs-list block types, and registry module signatures change frequently; this skill lets you read the truth from `registry.opentofu.org` instead of guessing from possibly-stale markdown.

## When to Use

- Validating a resource's block-type structure before writing a `*.tftest.hcl` assertion (set vs list vs computed)
- Looking up the latest stable provider or module version before pinning
- Discovering OpenTofu registry modules by topic, comparing input contracts
- Confirming an attribute name or type before referencing it in a resource block
- Running a one-shot "what's new in this provider major" check before a version bump
- Looking up an OpenTofu-only feature surface (state encryption 1.7+, provider iteration 1.7+) that wouldn't appear in the Terraform registry

## Setup

The OpenTofu MCP server is available two ways: a hosted SSE endpoint (recommended; zero install, no auth, Cloudflare-Workers-backed) or a local Node runner via `npx`. Neither requires Docker.

### Hosted SSE (recommended)

```bash
claude mcp add opentofu -t sse https://mcp.opentofu.org/sse
```

Hand-edit equivalent — add to `~/.claude.json` `mcpServers` block (or `.mcp.json` at the project root):

```json
{
  "mcpServers": {
    "opentofu": {
      "type": "sse",
      "url": "https://mcp.opentofu.org/sse"
    }
  }
}
```

### Local Node runner (alternative)

Use this path when you need offline/airgap operation or have a policy against hosted MCP endpoints:

```bash
claude mcp add opentofu -- npx -y @opentofu/opentofu-mcp-server
```

Hand-edit equivalent:

```json
{
  "mcpServers": {
    "opentofu": {
      "command": "npx",
      "args": ["-y", "@opentofu/opentofu-mcp-server"]
    }
  }
}
```

After restart, verify the server is connected with `claude mcp list` or `/mcp` — tools surface prefixed `mcp__opentofu__`.

> No auth, no env vars. The hosted endpoint and the local Node runner both query `registry.opentofu.org` and expose identical tools.

## Tools

The OpenTofu MCP server exposes five tools, all auth-free, all querying `registry.opentofu.org`.

| Tool | Use For |
|---|---|
| `mcp__opentofu__search-opentofu-registry` | Search providers, modules, resources, and data sources by topic, name, or namespace |
| `mcp__opentofu__get-provider-details` | Pull a provider's full surface — resources, data sources, versions, namespace |
| `mcp__opentofu__get-module-details` | Inspect a module's input/output contract and latest version |
| `mcp__opentofu__get-resource-docs` | Fetch documentation for a specific resource (attributes, block structure, examples) |
| `mcp__opentofu__get-datasource-docs` | Fetch documentation for a specific data source |

> **Tool-name format**: the OpenTofu server preserves hyphens in tool names (unlike the HashiCorp Terraform server, which uses underscores). Both formats are valid MCP tokens — Claude Code surfaces them as-is from the upstream registration. Verify with `/mcp` after install if you need exact strings for tool-allowlist configuration.

The OpenTofu server has no commercial-enterprise tier; there's no auth-required upgrade path. All five tools are available to every connected client.

## Workflow: Validate Before Asserting

Before writing a `*.tftest.hcl` assertion against a nested block, confirm the block-type from the live schema. The set-vs-list distinction is the most common source of LLM-generated test bugs and the most durable thing to look up rather than recall.

```text
1. mcp__opentofu__search-opentofu-registry({
     query: "aws s3_bucket_server_side_encryption_configuration",
     type: "resource"
   })
2. mcp__opentofu__get-resource-docs({
     provider: "aws",
     resource: "aws_s3_bucket_server_side_encryption_configuration"
   })
3. Read the schema. Note: is `rule` a `set` or a `list`? Is the inner block a list-of-1?
4. Write the assertion. Use `for` expressions for sets; `[0]` only for list-of-1.
```

## Workflow: Confirm Before Pinning

Before bumping a provider or module version constraint in `versions.tf`, confirm the latest stable version and surface known breaking changes. Static markdown ages on every provider release; the MCP server is the durable source of truth for the OpenTofu registry's view.

```text
1. mcp__opentofu__get-provider-details({ namespace: "hashicorp", name: "aws" })
   — the response includes the latest version alongside the provider surface
2. Compare against the current `versions.tf` constraint. Is the bump a major, minor, or patch?
3. For majors, flag breaking-change risk to the user before editing — pull provider release notes, scope the migration, and decide whether to pin to the previous major.
```

For modules, use `mcp__opentofu__get-module-details` — same shape, same logic, version surfaces in the response. Read the input/output contract while you're there, since a major-version bump is also when input signatures most commonly drift.

> **Response size**: `get-provider-details` returns the full provider surface (resources, data sources, versions) and can exceed 150 KB for large providers like `aws`. The response gets written to a tool-results file in `~/.claude/projects/.../tool-results/` and must be read in chunks with `jq` or `head`. For a quick version lookup, parse with `jq -r '.[0].text' <file> | head -c 500` to surface the leading "Latest Version:" line.

## Runtime Divergence

The OpenTofu MCP server queries `registry.opentofu.org`, which mirrors most-but-not-all of the public Terraform registry plus carries OpenTofu-only modules. Shared TF/OT resource and provider schemas resolve identically between the two registries through 1.x. Modules exclusive to `registry.terraform.io` (a small set; usually proprietary modules published only there) will miss via this server — fall back to the HashiCorp MCP server or the registry website for those.

> OpenTofu-only features (state encryption 1.7+, provider iteration 1.7+) are surfaced authoritatively by this server. Routing rule 4 below forces these queries through `mcp__opentofu__*` regardless of the binary-detection result.

## Routing: When Both MCP Servers Are Configured

If both the OpenTofu MCP server (`mcp__opentofu__*` tools) and the HashiCorp Terraform MCP server (`mcp__terraform__*` tools) are connected, prefer one server's tools over the other using the convention from [`rules/terraform/hooks.md`](../../rules/terraform/hooks.md):

1. **Env override**: if `ECC_TF_BINARY=tofu` is set, prefer `mcp__opentofu__*` tools. If `ECC_TF_BINARY=terraform`, prefer `mcp__terraform__*` tools.
2. **PATH detection**: if `tofu` is the only binary on PATH, prefer `mcp__opentofu__*`. If `terraform` is the only binary on PATH, prefer `mcp__terraform__*`. If both binaries are present and `ECC_TF_BINARY` is unset, default to `mcp__opentofu__*` (matches the hooks rule's "prefer tofu when ambiguous").
3. **File-extension tiebreaker**: when the rules above are ambiguous, the file being worked on settles it. `.tofu` → `mcp__opentofu__*`. `.tf` → fall back to the env/PATH default.
4. **OT-only feature override**: regardless of the rules above, route OpenTofu-only feature queries (state encryption 1.7+, provider iteration 1.7+) to `mcp__opentofu__*` — the HashiCorp server's registry doesn't carry OpenTofu-only resource schemas.

This routing is *agent-side guidance*, not an MCP-protocol enforcement. Both servers can be enabled simultaneously; the agent picks which server's tools to reach for based on the rules above. Users with strong preferences should set `ECC_TF_BINARY` explicitly.

## Cross-References

- [`skills/terraform-mcp/SKILL.md`](../terraform-mcp/SKILL.md) — sibling skill for the HashiCorp Terraform MCP server; routing rule above governs which to use when both are connected
- [`skills/terraform-testing/SKILL.md`](../terraform-testing/SKILL.md) — primary consumer; uses MCP for schema validation in tests
- [`skills/terraform-patterns/SKILL.md`](../terraform-patterns/SKILL.md) — version-management section; this skill replaces the snapshot-in-markdown approach with live lookup
- [`agents/terraform-reviewer.md`](../../agents/terraform-reviewer.md) — review tasks that need to confirm schema or version assumptions
- [`agents/terraform-build-resolver.md`](../../agents/terraform-build-resolver.md) — debugging schema-target errors during init/validate/plan
- [`rules/terraform/hooks.md`](../../rules/terraform/hooks.md) — canonical binary-detection convention mirrored by the Routing section above

---

> Uses the official OpenTofu MCP server (Mozilla Public License 2.0). See [opentofu/opentofu-mcp-server](https://github.com/opentofu/opentofu-mcp-server) for source and license.
