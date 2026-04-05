---
name: supabase
description: Use when working with Supabase — auth, RLS, pgvector/hybrid search, Edge Functions, schema design, or migrations. Covers security constraints, common gotchas, and architectural patterns from production use.
---

# Supabase Development Patterns

## Core Architecture Rules

| Concern | Rule |
|---------|------|
| Anon key | Safe to expose client-side. Restricted by RLS. SELECT only on public data. |
| Service role key | Bypasses RLS entirely. **Never** in frontend code. Migration scripts only. |
| RLS | Enable on every table. RLS restricts *rows*. Does not restrict columns. |
| Column-level grants | Required whenever a table mixes public fields and PII. Second defence layer. |

---

## Security: RLS + Column-Level Grants

RLS alone is not enough when a table mixes public and private columns.

```sql
-- profiles: id, display_name, avatar_url, email
-- RLS restricts which rows are visible.
-- Column-level GRANT restricts which columns on visible rows.

REVOKE SELECT ON profiles FROM authenticated;
GRANT SELECT (id, display_name, avatar_url) ON profiles TO authenticated;
-- email is now inaccessible to authenticated users — not nulled, genuinely blocked.
```

**When to apply:** Any table with PII alongside publicly safe fields.
**Why:** A future RLS policy misconfiguration will not leak PII if column grants are also in place.

---

## Auth: Framework-Agnostic Callback Bridge

Never couple an auth package to a specific framework's state mechanism (EventBus, Redux, Zustand). Accept callbacks at construction time:

```typescript
new AuthManager(supabase, {
  onSignIn:  (user, session) => { /* caller bridges to their AppState */ },
  onSignOut: ()              => { /* caller clears their state */         },
  onError:   (err)           => { /* caller decides display */            },
});
```

The `AuthManager` fires callbacks. The consuming app bridges to its own state. `auth/` stays framework-agnostic and reusable across apps in the same monorepo.

---

## Auth Gotcha: Session Expiry on Page Load

`getSession()` returns the stored session even if it has already expired. Always validate `expires_at`:

```typescript
const { data: { session } } = await supabase.auth.getSession();
if (session) {
  const isExpired = session.expires_at
    ? Date.now() / 1000 > session.expires_at
    : false;
  if (!isExpired) {
    this.callbacks.onSignIn?.(session.user, session);
  }
  // If expired: let onAuthStateChange fire TOKEN_REFRESHED / SIGNED_OUT naturally.
}
```

`onAuthStateChange` handles token refresh automatically — do not fire `onSignIn` on an expired session.

---

## Auth Security Checklist

Three gotchas that are easy to miss in a first pass:

### 1. Generic error messages (enumeration prevention)

```typescript
// Wrong — leaks whether the email exists
if (error.message === 'User not found') return 'Aucun compte avec cet email';

// Correct — same message for every failure
return 'Identifiants invalides. Veuillez réessayer.';
```

### 2. Client-side sliding-window rate limiting

```typescript
const RATE_LIMIT = { maxAttempts: 5, windowMs: 60_000 };
const attempts: number[] = [];

function isRateLimited(): boolean {
  const now = Date.now();
  while (attempts.length && attempts[0] < now - RATE_LIMIT.windowMs) attempts.shift();
  return attempts.length >= RATE_LIMIT.maxAttempts;
}
// Before every signIn/signUp call:
if (isRateLimited()) throw new Error('Trop de tentatives. Réessayez dans une minute.');
attempts.push(Date.now());
```

Not a security guarantee (API callable directly), but catches brute force and accidental loops.

### 3. Same-origin validation for OAuth redirectTo

```typescript
function safeRedirectUrl(redirectTo?: string): string {
  const base = window.location.origin;
  if (!redirectTo) return base;
  try {
    const url = new URL(redirectTo, base);
    if (url.origin !== base) return base; // reject cross-origin
    return url.toString();
  } catch { return base; }
}
// Pass to: supabase.auth.signInWithOAuth({ options: { redirectTo: safeRedirectUrl(r) } })
```

### 4. peerDependency for auth packages in monorepos

Declare `@supabase/supabase-js` as a `peerDependency` in shared packages to prevent two separate Supabase client instances (two session caches, divergent auth state):

```json
// auth/package.json
{
  "peerDependencies": { "@supabase/supabase-js": "^2" }
}
```

---

## Database: pgvector + Hybrid Search

### Schema pattern

```sql
-- Promote frequently-queried fields. JSONB for type-specific remainder.
CREATE TABLE nodes (
  id          TEXT PRIMARY KEY,
  node_type   TEXT NOT NULL,
  label       TEXT,
  embedding   vector(384),          -- HNSW index for cosine similarity
  search_text tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('french', coalesce(label,'')), 'A') ||
    setweight(to_tsvector('french', coalesce(description,'')), 'C')
  ) STORED,
  data        JSONB                  -- type-specific fields, no migrations needed
);

CREATE INDEX ON nodes USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON nodes USING gin (search_text);
```

**Key rule:** `GENERATED ALWAYS AS` requires IMMUTABLE functions. Wrap `unaccent()`:
```sql
CREATE OR REPLACE FUNCTION immutable_unaccent(text) RETURNS text
  LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT unaccent($1) $$;
```

### Hybrid search (70/30 BM25 + vector)

```sql
CREATE OR REPLACE FUNCTION search_nodes(
  query_text      TEXT,
  query_embedding vector(384),
  top_k           INT DEFAULT 10
) RETURNS TABLE(...) AS $$
  WITH
  vector_hits AS (
    SELECT id, 1 - (embedding <=> query_embedding) AS vscore
    FROM nodes ORDER BY embedding <=> query_embedding LIMIT top_k * 2
  ),
  text_hits AS (
    SELECT id, ts_rank_cd(search_text, plainto_tsquery('french', query_text)) AS tscore
    FROM nodes
    WHERE search_text @@ plainto_tsquery('french', query_text)
    LIMIT top_k * 2
  )
  SELECT n.id, n.label, n.node_type,
    COALESCE(v.vscore, 0) * 0.7 + COALESCE(t.tscore, 0) * 0.3 AS score,
    CASE WHEN v.vscore IS NOT NULL AND t.tscore IS NOT NULL THEN 'both'
         WHEN v.vscore IS NOT NULL THEN 'vector' ELSE 'bm25' END AS match_type
  FROM nodes n
  LEFT JOIN vector_hits v USING (id)
  LEFT JOIN text_hits t USING (id)
  WHERE v.id IS NOT NULL OR t.id IS NOT NULL
  ORDER BY score DESC LIMIT top_k;
$$ LANGUAGE sql;
```

**70/30 ratio:** 0.7 * cosine + 0.3 * BM25. Adjust for domain: technical glossaries lean more BM25; prose/conceptual domains lean more vector.

**Embedding model:** The client must embed queries with the **same model** used at index time. If nodes are indexed with `BAAI/bge-small-en-v1.5` (384-dim), queries must use that model. Use `@xenova/transformers` in the browser for client-side embedding (~50 MB, cached after first load).

---

## Edge Functions vs Direct RPC

| Need | Use |
|------|-----|
| Multi-step pipeline (search → funnel → context) | Edge Function — one round-trip |
| Business logic requiring server secrets | Edge Function |
| Single RPC with no orchestration | `supabase.rpc(...)` direct |
| Node/row detail fetch | Direct RPC |

Edge Functions run in the Deno runtime — no long-running processes, no `npm install` at runtime. Bundle dependencies at deploy time.

```typescript
const { data, error } = await supabase.functions.invoke('my-function', {
  body: { query: "tristesse", top_k: 10 }
});
```

---

## Migration Pattern (Nix)

```bash
nix run .#migrate                      # Full migration (data + embeddings)
nix run .#migrate -- --skip-embeddings # Skip embedding generation (fast)
nix run .#migrate -- --schema-only     # Tables + functions only, no data
nix run .#validate                     # Post-migration validation checks
```

Run validation checks after every migration — assert row counts, FK integrity, index presence.

---

## Errors to Avoid

### 1. `getSession()` returns expired sessions
**Symptom:** UI shows user as logged in; all API calls return 401.
**Fix:** Check `expires_at` manually (see Auth Gotcha above). Prefer `onAuthStateChange` for reactive state.

### 2. RLS without column grants leaks PII
**Symptom:** Authenticated users read other users' emails from `profiles`.
**Fix:** `REVOKE SELECT ON profiles FROM authenticated; GRANT SELECT (id, display_name, avatar_url) ON profiles TO authenticated;`

### 3. Service role key exposed client-side
**Symptom:** Any client can bypass RLS — full table access.
**Fix:** Service role key in server-side only (Edge Function env vars, migration scripts). Never in frontend bundles or committed `.env` files.

### 4. Generic `signIn` error messages leak email existence
**Fix:** Collapse all auth failures to one message. Log the real error server-side.

### 5. Duplicate Supabase client instances in monorepos
**Symptom:** Sign-in doesn't propagate; two session caches; `onAuthStateChange` fires on only one.
**Fix:** Declare `@supabase/supabase-js` as `peerDependency` in shared packages.

### 6. `tsvector` generated column with mutable function
**Symptom:** `ERROR: generation expression is not immutable` at table creation.
**Fix:** Wrap `unaccent()` in an `IMMUTABLE` wrapper before using in `GENERATED ALWAYS AS`.

### 7. Binary text matching instead of scored BM25
**Symptom:** Hybrid search scores are always 0 or 1 for the text component — fusion is not a real blend.
**Fix:** Use `ts_rank_cd()` for float-scored BM25. `CONTAINS`-style matching cannot produce hybrid weights.
