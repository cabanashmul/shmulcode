# Migrating from v1

## What changed

| | v1 | v2 |
|---|---|---|
| Scope | config framework: 22 agents, 5 skills, `qrouter` | launcher layer only: one parameterized wrapper, three provider instances |
| Entry point | hand-written `private/*.nix` wrappers | `nix run …#<instance>`, `packages.default`, `programs.shmulcode.*` |
| Provider config | scattered per wrapper | entirely in the runtime env file |

v1 is **not lost**: it lives on branch `v1` and tag `v1.0.0`.

```bash
git fetch --tags
git switch v1        # the old tree
# or: git show v1.0.0:<path>
```

The v2 rewrite replaced `main` in place, so no force-push was involved and the v1
history is intact.

## The `mimo` → `mimocode` rename

The old command was `mimo`; the instance is now `mimocode`. Two ways to cope:

- Use `mimocode` (recommended — it matches the instance/env-file name).
- Keep the old binary name via the Home Manager module:

  ```nix
  programs.shmulcode.instances.mimocode = {
    enable = true;
    command = "mimo";     # binary name only
    envFile = config.age.secrets."mimocode-env".path;
  };
  ```

  A renamed binary still resolves `<instance>/env` (here `mimocode`), so the env
  file and the `shmulcode init mimocode` hint stay correct.

## Moving an existing setup

1. Point the launcher at your existing env file. Either set
   `programs.shmulcode.instances.<name>.envFile` to it, or run
   `shmulcode init <name>` and paste the values in.
2. Delete any hand-written wrapper (the old `private/mimocode.nix` /
   `private/deepcode.nix` style files). They were the copy-paste drift this
   project exists to remove.
3. Keep provider config in the env file. For example, DeepSeek:

   ```bash
   export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
   export ANTHROPIC_MODEL="deepseek-flash"
   export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-flash"
   export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-flash"
   export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-flash"
   export ANTHROPIC_AUTH_TOKEN="…"
   ```

   Mapping all three aliases to one model avoids 404s in the `/model` picker when
   the provider serves only one model.

4. Do **not** put provider variables in `home.sessionVariables` — that leaks one
   provider's routing into every `claude` invocation in the session. Per-process
   env-file sourcing is the contract.

## Verifying the move

```bash
shmulcode list                       # all three instances, env paths, present/missing
shmulcode doctor mimocode            # resolution trace + variable presence
mimocode --version                   # reaches the real claude
mimocode                             # TUI opens; Ctrl-C returns cleanly
```
