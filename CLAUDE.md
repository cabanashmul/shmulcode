# Claude Global Instructions

## Task Orchestration

### Direct commands (bypass manager)
These short commands invoke a single post-agent directly — no manager needed:
- **"commit"** → `Agent(subagent_type: "committer")` — commit current changes
- **"test"** → `Agent(subagent_type: "tester")` — run tests and code review
- **"document"** → `Agent(subagent_type: "documenter")` — update docs for recent changes
- **"learn"** → `Agent(subagent_type: "learner")` — write vault notes from recent work

### Everything else → plan then execute
Subagents cannot spawn other subagents (Claude Code architectural constraint).
The main conversation is the only executor. The flow is:

1. **Plan** — Spawn the manager to research and return a structured plan
2. **Advise** — Spawn advisors listed in the plan (in parallel). Advisors have NO tools — manager must embed all context in their prompts. If an advisor returns NEED_CONTEXT, provide the missing info and re-invoke.
3. **Execute** — Spawn specialists with advisor constraints baked into prompts (parallel where no dependencies)
4. **Audit** — Spawn the auditor with advisor constraints + FILES_CHANGED to verify compliance
5. **Verify** — tester → committer → documenter → learner (sequential, except documenter + learner in parallel)

### Execution protocol

#### Step 1: Get the plan
```
Agent(subagent_type: "manager", prompt: "Task description + full context")
→ returns: VAULT_CONTEXT, ADVISORS, SUBTASKS, POST_AGENTS
```

#### Step 2: Run advisors (parallel)
For each advisor in the plan:
```
Agent(subagent_type: "security-advisor", prompt: "from plan")
Agent(subagent_type: "architecture-advisor", prompt: "from plan")
```
Collect constraints from all advisors.

#### Step 3: Run specialists
Append advisor constraints to each subtask prompt, then spawn:
```
Agent(subagent_type: "app-specialist", prompt: "subtask prompt + advisor constraints")
```
Respect `depends_on` — only spawn a subtask after its dependencies complete.
Launch independent subtasks in parallel.

#### Step 4: Audit against advisor constraints
```
Agent(subagent_type: "auditor", prompt: "advisor constraints + FILES_CHANGED from specialists")
→ PASS: all constraints satisfied, proceed to Step 5
→ FAIL: send violations back to relevant specialist for remediation, then re-audit (max 3 retries)
```

#### Step 5: Post-agents (sequential chain)
```
Agent(subagent_type: "tester") → PASS/FAIL
  FAIL → fix with specialist (max 3 retries) → re-test
  PASS → Agent(subagent_type: "committer")
       → Agent(subagent_type: "documenter") + Agent(subagent_type: "learner") [parallel]
```

### Agent Roster

**Planner**
- `manager` (opus) — researches codebase, searches vault, returns structured execution plan

**Advisors** — pre-flight, return constraints not code, NO tools (all context must be in prompt)
- `security-advisor` (opus) — auth, PII, external I/O, secrets, RBAC
- `architecture-advisor` (opus) — new services, cross-cutting changes, schema design
- `performance-advisor` (sonnet) — hot paths, DB queries, API latency
- `cost-advisor` (haiku) — IaC changes, scaling config, new infra resources
- `dependency-advisor` (haiku) — new libraries, services, external dependencies

**Specialists** — write code, return output contracts, do NOT commit
- `frontend-specialist` (sonnet) — React, TypeScript, HTML, CSS, client-side
- `backend-specialist` (sonnet) — APIs, server logic, auth, business rules
- `db-specialist` (sonnet) — schema, migrations, queries, data modelling
- `iac-specialist` (sonnet) — Nix flakes, Helm, Terraform, env config
- `devops-specialist` (sonnet) — CI/CD pipelines, deployment automation, monitoring
- `app-specialist` (sonnet) — games, desktop apps, CLI tools, scripts
- `finance-specialist` (sonnet) — billing, payments, invoicing, pricing
- `network-specialist` (sonnet) — ingress, DNS, TLS, service mesh, load balancing
- `data-specialist` (sonnet) — ETL, pipelines, analytics schema, reporting

**QA** — called during planning phase
- `qa-specialist` (sonnet) — test strategy, coverage standards, pass conditions

**Auditor** — post-implementation, verifies specialist output against advisor constraints
- `auditor` (sonnet) — reads changed files, checks each constraint, returns per-constraint PASS/FAIL

**Post-agents** — run after audit passes
- `tester` (sonnet) — pre-checks, tests, code review → PASS/FAIL verdict
- `committer` (haiku) — atomic git commit after PASS (only agent that commits)
- `documenter` (haiku) — READMEs, API docs, changelogs (not vault notes)
- `learner` (sonnet) — Zettelkasten notes, vault pruning (not project docs)

### Advisor protocol
Advisors have **no tools**. They cannot read files. The manager must embed all relevant context (code snippets, file contents, directory structure, architecture descriptions) directly in each advisor prompt. If an advisor returns a `NEED_CONTEXT` response, provide the missing information and re-invoke.

### Retry policy
- Max 3 retries per specialist per subtask
- After 3 failures, escalate to the user with: what was attempted, what failed, root cause guess

### Specialist output contract
Every specialist returns:
```
STATUS: done | blocked
FILES_CHANGED: [list]
NOTES: [caveats, decisions]
BLOCKED_REASON: [if blocked]
```

### Commit discipline
- Only the `committer` agent creates commits
- All other agents must NOT run git commit
- Stage files by name — never `git add -A` or `git add .`
- Never amend, never skip hooks, never force push

### Nix package policy
- **One-off or temporary tools**: use `nix-shell -p <pkg>` (never install globally)
- **Project development dependencies**: add to `flake.nix` devShell, use `nix develop`
- If a `nix-shell -p` package is needed in 3+ sessions, promote it to the flake

---

## Obsidian Vault as Persistent Memory

You have access to an Obsidian vault at `/home/shmul95/shmulistan`.
This vault serves as your persistent memory across sessions.
The vault has its own `CLAUDE.md` with detailed conventions for
folder structure, note naming, Zettelkasten method, and workflows.
**Always defer to the project CLAUDE.md** for vault-specific rules.

---

## On Every Session Start
1. Run `git pull` in the vault to sync latest changes
2. Read `index.md` for a map of existing knowledge
3. Search the vault using keywords from the user's first message
4. Read any matching notes before responding

---

## When to Write Notes
Write to the vault when you learn something reusable:
- A user preference or habit ("I prefer X", "always do Y")
- A non-obvious solution or workaround you found
- A project decision or its reasoning
- Any fact about the user's environment or setup

**How to write:** Follow the vault's Zettelkasten conventions
(note format, naming, folder placement) as defined in the
project CLAUDE.md at `/home/shmul95/shmulistan/CLAUDE.md`.

---

## Searching for Connections
Every time you write or update a note:
1. Search the vault for notes sharing at least one tag with the new note
2. For each match that is meaningfully related, add it to `related:` frontmatter of both notes
3. If two notes cover the same topic and could be merged, suggest it

When answering a question:
1. Search 2-3 variations of the topic, not just the most obvious note
2. If multiple notes are relevant, reason over all of them together
3. Mention connections the user may not have noticed

---

## On Session End (when asked to wrap up)
- Write a short session summary to `00_Inbox/` for later processing
- Update `related:` fields if new connections were found
- Commit and push all changes

---

## Git Commit Discipline
- Make small, atomic commits — one logical change per commit
- Each commit message should fit on a single line
- Commit after each completed step of a plan, not at the end
- This keeps the history readable and makes resuming from partial work easier
- Never co auther yourself on commits
