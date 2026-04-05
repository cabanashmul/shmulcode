---
name: deterministic-llm-architecture
description: Use when designing AI-driven automation systems — pipelines where LLMs reason over computed results rather than raw data. Covers the tools→reviewer→output pattern, two operating modes (scripted vs dynamic), prompt design, calibration, and anti-patterns. Applicable to finance, code review, data pipelines, and any precision domain.
---

# Deterministic LLM Architecture: Tools → Reviewer → Output

## The Core Pattern

```
[Deterministic Tools]  ←— exact computation, retrieval, arithmetic
        ↓
   [Structured Payload]  ←— fully computed, validated, no ambiguity
        ↓
[LLM Reviewer]  ←— domain rules + institutional memory + judgment
        ↓
  [Structured Output]  ←— report, email, decision, vault note, PR
```

**The critical invariant:** the LLM never touches numbers or raw data directly. It receives a fully computed, validated payload. Its job is to interpret, synthesise, explain, and narrate — not to compute.

---

## Why This Pattern Converges

Two independent forces push every production AI system toward this shape:

**LLM limitations (what to offload):**
- Arithmetic and exact calculation — models hallucinate figures
- SQL-style exact retrieval from large datasets
- Deterministic rule application (is this value within tolerance?)
- Data format transformation with no loss

**LLM strengths (what to keep):**
- Anomaly recognition in a sea of numbers
- Applying domain rules to assess severity
- Synthesising multiple signals into a coherent narrative
- Writing natural language that reflects institutional context
- Judgment calls where "correct" is not computable

**Design rule:** draw a hard boundary. Everything requiring exact answers → deterministic tool. Everything requiring judgment → prompt.

---

## Two Operating Modes

### Mode A — Scripted Orchestration (recurring, predictable workflows)

The pipeline is a fixed sequence of function calls. The LLM is invoked exactly once, at the end, with the full computed result as context.

```python
# Fixed pipeline — no LLM tool routing
def daily_reconciliation():
    positions   = fetch_positions()          # deterministic
    transactions= fetch_transactions()       # deterministic
    deviations  = reconcile(positions, transactions)  # deterministic
    tolerances  = apply_tolerance_rules(deviations)   # deterministic

    report = llm_review(
        payload=tolerances,
        rules=REGULATORY_RULES,
        memory=INSTITUTIONAL_CONTEXT,
    )
    send_report(report)
```

**When to use:** daily scheduled jobs, regulatory reports, CI code review pipelines, anything where the workflow steps are known in advance. Tolerates zero non-determinism because the stakes are high (regulatory, financial).

### Mode B — Dynamic Tool Selection (ad-hoc, user-driven queries)

The LLM acts as orchestrator, selecting which tools to call and in what order to answer a free-form question.

```
User: "Why did our EUR cash position drop 3% yesterday?"
  → LLM selects: fetch_fx_rates, fetch_transaction_log, fetch_counterparty_data
  → LLM synthesises answer from results
```

**When to use:** exploratory queries, interactive assistants, scenarios where the computation path is unknown ahead of time. Tolerates more non-determinism because the output is informational, not regulatory.

**Key distinction:** Mode A for production automation; Mode B for decision support.

---

## Where This Pattern Appears

| Domain | Tools (deterministic) | Reviewer (LLM) | Output |
|--------|----------------------|----------------|--------|
| **Finance / Treasury** | ETL, reconciliation, FX rates, tolerance checks | Claude reviews deviations, applies regulatory rules, flags anomalies | PDF report, email alert |
| **Autonomous code review** | Static analysis, test runners, linters | Agent reviews output, decides to escalate or retry | GitHub issue, PR |
| **AI hackathon (pet store)** | `calculate_price`, inventory lookup | Supervisor LLM writes customer-facing response | Natural language reply |
| **Bloomberg disruption thesis** | Market feeds, price aggregation | Analytical layer: screening, interpretation, narrative | Research report |
| **CI pipeline** | Build logs, test results, coverage | LLM summarises failures for the developer | Notification, ticket |
| **Knowledge graph update** | Graph diff, schema validation | LLM assesses impact, writes change summary | Changelog, review request |

---

## Prompt Design for the Reviewer Step

The LLM prompt for the reviewer role has a specific structure:

```
CONTEXT: [who the reviewer is, what domain, what rules apply]
COMPUTED RESULTS: [the full deterministic payload — never raw data]
DOMAIN RULES: [regulatory thresholds, style guides, acceptance criteria]
INSTITUTIONAL MEMORY: [past decisions, known exceptions, preferred formats]
TASK: [what the output should be — report, decision, narrative]
```

**What goes in COMPUTED RESULTS:**
- Already-reconciled figures with deviation amounts and percentages
- Pre-classified findings (within tolerance / outside tolerance / critical)
- Structured summaries — not raw DB dumps or log files

**What stays out:**
- Raw numbers that require arithmetic to interpret
- Unfiltered logs — the LLM will hallucinate patterns in noise
- Data with ambiguous schema — normalise before passing

---

## Calibration: Managing Signal-to-Noise Over Time

In automated code review and similar pipelines, the signal-to-noise ratio degrades as the system matures — obvious issues are fixed, leaving harder, subtler ones that the LLM is more likely to mischaracterise.

**Observed failure mode — cross-function consistency false positives:**

LLM agents frequently flag CRITICAL bugs for "parameter type mismatches" across function calls when the code is actually correct. This happens because the agent analyses call sites in isolation without tracing data flow:

```
// Agent flags: IsQueued() uses full repo name, HasActiveContainer() uses slug — BUG?
// Reality: HasActiveContainer() internally handles both formats. No bug.
```

Prone to false positives when:
1. Different functions use different key formats for the same entity
2. Format conversion happens inside the callee, not at the call site
3. Multiple data representations coexist by design

**Mitigations:**
- Always manually verify any CRITICAL finding before acting on it
- Add a severity filter step: LLM classifies findings → deterministic filter drops LOW/MEDIUM that match known false-positive patterns
- Provide function signatures and call-site context together, not separately
- After several runs, extract recurring false-positive patterns into explicit instructions in the reviewer prompt

---

## Anti-Patterns

| Anti-pattern | Problem | Fix |
|---|---|---|
| LLM does arithmetic | Hallucinated figures in reports | Always use a `calculate()` tool |
| LLM filters a raw dataset | Misses rows, hallucinates matches | Run SQL/pandas filter first; pass summary |
| LLM selects exact values from a large list | Confabulates options | Run exact lookup deterministically; pass result |
| Mode B for regulatory reports | Non-deterministic tool selection → missing steps | Use Mode A with a fixed pipeline |
| LLM invoked on every pipeline step | Slow, expensive, unreliable | Invoke once at the end on the final payload |
| Reviewer prompt without domain rules | LLM applies generic heuristics | Embed rules explicitly as numbered constraints |
| No human-in-the-loop for critical output | LLM judgment errors ship directly | Add approval gate for high-stakes outputs |

---

## n8n Implementation

This pattern maps cleanly onto n8n workflows:

```
[Schedule Trigger]
  → [Code Node: fetch + compute]          ← deterministic
  → [Code Node: reconcile + classify]     ← deterministic
  → [Anthropic Claude: review payload]    ← LLM reviewer (invoked once)
  → [Send Email / Slack / Postgres]       ← structured output
```

For Mode B (dynamic), use an **AI Agent (Tools Agent)** node with tools pointing to sub-workflows that encapsulate the deterministic functions.

**Key:** the LLM node receives a structured JSON payload — not raw database records. The Code nodes upstream are the "deterministic tools" layer.

---

## Checklist When Designing a New Pipeline

1. List every step: mark each as "exact computation" or "judgment"
2. All "exact computation" steps → functions/tools/SQL, never LLM
3. All "judgment" steps → LLM, with computed inputs
4. Choose Mode A (scripted) or Mode B (dynamic) based on whether the workflow is known ahead of time
5. Design the reviewer prompt: context + computed results + explicit domain rules
6. Add severity filter for automated pipelines to suppress known false-positive categories
7. Add human approval gate for outputs with irreversible consequences
