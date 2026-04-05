---
name: n8n
description: Use when building or debugging n8n workflows — connecting triggers, wiring AI agents, handling webhooks, deploying self-hosted instances, or integrating Claude via MCP or HTTP. Covers architecture, AI/LangChain patterns, community edition limits, and common gotchas.
---

# n8n Workflow Automation

## What n8n Is

Fair-code workflow automation platform (Sustainable Use License — free for internal use, cannot resell as SaaS). Visual node editor + full JavaScript/Python in Code nodes. 1,200+ built-in integrations, 5,800+ community nodes.

**Edition choice:**
| Need | Edition |
|------|---------|
| Personal / internal automation | Community (self-hosted, free) |
| SSO, RBAC, source control, audit logs | Enterprise (self-hosted, paid) |
| Managed, no ops | Cloud |

---

## Architecture

### Execution Modes

**Regular (default):** single Node.js process — API, UI, webhooks, execution all in one. Fine for dev and small deployments.

**Queue mode (production):** Redis + Bull separates concerns. Main instance handles webhooks and triggers; workers execute workflows. Required for horizontal scaling.

```
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=redis
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
```

**Task runners (v2.0+):** Code nodes run in isolated containers (`n8nio/runners`), not the main process. External runners are the secure default. Internal runners (`N8N_RUNNERS_MODE=internal`) trade isolation for simplicity.

### Database

SQLite (dev), PostgreSQL (production). MySQL/MariaDB removed in v2.0.

```
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=localhost
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=<secret>
```

n8n is **memory-bound**, not CPU-bound — monitor RAM, not CPU.

---

## Core Concepts

### Triggers (entry points)

| Trigger | Use |
|---------|-----|
| Schedule | Cron / interval — polling, daily jobs |
| Webhook | HTTP push — GitHub events, Stripe hooks |
| Chat | Interactive chatbot / AI assistant |
| MCP Server | External AI agents call workflow as MCP tools |
| Manual | Testing in the editor |
| Error | Runs when a linked workflow fails |

**Rule:** one trigger per workflow (Community edition). Split different trigger types into separate workflows. Fan-out from one trigger to multiple parallel branches is fully supported.

### Expressions

JavaScript in `{{ }}`, available in any node parameter field:

```javascript
{{ $json.name }}                           // field from current item
{{ $("Fetch User").first().json.id }}      // first output from named node
{{ $now.toFormat("yyyy-MM-dd") }}          // Luxon datetime
{{ $env.MY_VAR }}                          // env var (Community alternative to Variables)
{{ $vars.apiKey }}                         // n8n Variables (Enterprise/Cloud only)
```

### Sub-workflows

Use **Execute Sub-workflow** to compose reusable units. Keep each workflow to 5–10 nodes; extract repeated logic into sub-workflows. Two modes: run once for all items, or once per item.

### Save vs Publish (v2.0)

Saving a workflow does NOT affect production. **Publish** explicitly to deploy changes to the active trigger. Test URL (`/webhook-test/`) works without publishing; production URL (`/webhook/`) requires the workflow to be active.

---

## AI / Claude Integration

### The Standard Pattern

```
[Chat Trigger]
  → [AI Agent: Tools Agent]
       ├── LLM: Anthropic Claude (claude-sonnet-4-6 or claude-haiku-4-5)
       ├── Memory: PostgreSQL Chat Memory
       └── Tools:
            ├── [Workflow Tool: "Search Knowledge Base"]
            ├── [MCP Client Tool: External MCP Server]
            └── [Custom Code Tool: Data Transform]
  → [Respond to Webhook]
```

**Tools Agent** is the default choice — it coordinates multiple tools for task completion. Use Conversational Agent when you need stateful dialogue without tool use.

### MCP Integration

**n8n as MCP server** — expose any workflow as a callable tool for Claude or Cursor:
- Add **MCP Server Trigger** as the workflow trigger.
- Claude discovers the tool and calls it via SSE or streamable HTTP.

**n8n calling external MCP servers** — add **MCP Client Tool** inside an AI Agent node to give the agent access to tools from external MCP servers.

### Calling Claude Without an API Key (ClaudeSDK Bridge)

If Claude Code CLI subscription is available, wrap it in a FastAPI HTTP server and call it from n8n via HTTP Request node:

```
[HTTP Request: POST http://localhost:8100/chat]
Body: { "prompt": "...", "model": "haiku" }
```

This avoids API billing while reusing the existing subscription for automation workflows.

### LLM Providers Available

Anthropic Claude, OpenAI, AWS Bedrock, Google Gemini/Vertex, Azure OpenAI, Ollama (local/free), Mistral, Groq, DeepSeek, xAI Grok, OpenRouter.

---

## Webhook Patterns

### GitHub Event Router

```
[Webhook: POST /github-events]
  → [Switch: on {{ $json.headers["x-github-event"] }}]
      ├── "push"         → [Process Push]
      ├── "pull_request" → [Process PR]
      └── default        → [No-Op]
```

### Webhook with Validation

```
[Webhook: POST /api/submit]
  → [If: {{ $json.body.email && $json.body.name }}]
      ├── true  → [Process] → [Respond to Webhook: 200]
      └── false → [Respond to Webhook: 400]
```

### Response Modes

| Mode | Behaviour |
|------|-----------|
| Immediately | Returns 200 at once; workflow continues in background |
| Using Respond to Webhook | Waits; returns whatever the downstream node sends |
| Last Node | Returns last node's output |

### Reverse Proxy Config (Critical)

Set `WEBHOOK_URL` to the external domain. Without it, webhook URLs will reference `localhost`:

```
WEBHOOK_URL=https://n8n.yourdomain.com/
```

---

## Error Handling

### Node-Level

- **Retry on Fail** — always enable on HTTP Request nodes (external APIs fail transiently).
- **Continue on Fail** — for non-critical nodes where the workflow must proceed regardless.
- **Stop on Fail** (default) — halt at the failed node.

**Gotcha:** "Retry on Fail" + "Continue on Fail" on the same node can be incompatible — retry settings may be silently ignored.

### Centralised Error Workflow

Create one dedicated error workflow triggered by the **Error Trigger** node. Assign it to all production workflows via workflow settings:

```
[Error Trigger]
  → receives: workflow ID, execution ID, error message, failed node
  → [Slack: notify #alerts]
  → [Postgres: log error row]
```

### Error Branches (In-Workflow Fallback)

```
[HTTP Request: Primary API]
  ├── success → [Process]
  └── error   → [HTTP Request: Fallback API] → [Process]
```

---

## n8n for Agent Orchestration (A3N1 Pattern)

n8n handles the "glue" layer of an autonomous agent system — scheduling, polling, branching, retries, notifications. Custom code handles stateful and interactive components.

**n8n owns:**
- Periodic polling (Schedule Trigger every 5 min)
- GitHub webhook reception → route to agent containers
- Token budget monitoring (call usage API, set lock flag)
- Notifications (Slack/email on PR merge or failure)
- Maintenance (prune stale checkpoints, archive completed work)

**Custom code owns:**
- Container lifecycle management (kubectl)
- TUI / real-time log streaming
- gRPC-based coordination
- Stateful checkpoint state machine

Pattern: n8n calls `kubectl` or `HTTP Request` (to FastAPI wrappers) rather than reimplementing everything in workflows.

---

## Community Edition Gotchas

### Variables require a paid plan

The Variables sidebar in the UI is visible but non-functional on Community. Creating or reading variables silently fails or errors.

**Workaround:** use environment variables passed to Docker:
```
$env.MY_VARIABLE_NAME
```
Defined in Docker Compose `.env` file, globally available, version-controllable.

### One trigger per workflow

A workflow cannot have both a Schedule Trigger and a Webhook Trigger. The second trigger is ignored.

**Workaround:** split into two separate workflows.

### Fan-out from one trigger is supported

One trigger → multiple parallel branches is valid and runs concurrently within a single execution. This is not a limitation.

---

## API Gotcha: Importing Workflow JSON

Posting a raw workflow export to `POST /api/v1/workflows` fails or corrupts state. Strip three field categories first:

```bash
jq 'del(.meta) | del(.tags) | .nodes = (.nodes | map(del(.id)))' workflow.json > clean.json

curl -X POST "http://localhost:5678/api/v1/workflows" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d @clean.json

# Activation is a SEPARATE call — import leaves workflow inactive
curl -X POST "http://localhost:5678/api/v1/workflows/$WORKFLOW_ID/activate" \
  -H "X-N8N-API-KEY: $N8N_API_KEY"
```

| Field | Why strip |
|-------|-----------|
| `meta` | Conflicts with server's own metadata |
| `tags` | Tag IDs reference source instance — don't exist on target |
| `nodes[].id` | Causes duplicate key conflicts |

---

## Security

- **`N8N_ENCRYPTION_KEY`**: set to a 64-hex-char string at first deploy. Cannot change later without re-encrypting all credentials. Same key must be on all workers in queue mode.
- **`N8N_BLOCK_ENV_ACCESS_IN_NODE=true`**: default in v2.0 — prevents Code nodes from reading env vars (prevents secret exfiltration).
- **No hardcoded secrets**: use n8n credential manager or external secret store (HashiCorp Vault). Never store secrets in workflow parameters.
- **TLS**: enable for all data in transit.
- **External task runners**: run Code nodes in isolated containers, not the main process.

---

## Performance

- Filter on triggers: reject irrelevant events before they enter the workflow body.
- Process incrementally: track `last_processed_id`, not full scans.
- Use Loop Over Items for large datasets to avoid memory exhaustion.
- Set `EXECUTIONS_DATA_MAX_AGE` to prune old execution logs from the database.
