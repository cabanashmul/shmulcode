# shmulcode

Provider-multiplexed launchers for [Claude Code](https://code.claude.com).

One trustworthy command per provider — **the only difference between providers is
the env file**. `mimocode`, `deepcode`, and `grokcode` are generated from a single
parameterized wrapper; adding a provider is a data entry, not a copy-paste.

```
nix run github:shmul95/shmulcode#mimocode -- --version
```

## What you get

| Output | Purpose |
|--------|---------|
| `packages.<name>` / `apps.<name>` | one launcher per provider (`mimocode`, `deepcode`, `grokcode`) |
| `packages.default` | `symlinkJoin` of the three launchers **plus** the `shmulcode` admin command — no bare `claude` |
| `homeManagerModules.default` | `programs.shmulcode.*` options (also alias'd as `homeModules.default`) |

The `claude` binary is supplied by the flake (from its pinned nixpkgs), never
looked up on `PATH`.

## Quickstart

```bash
# Create an env file template (0600, comments only — it never contains values)
nix run github:shmul95/shmulcode#shmulcode -- init mimocode
$EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/mimocode/env"

# Run it. Everything after `--` goes to claude untouched.
nix run github:shmul95/shmulcode#mimocode -- --version
nix run github:shmul95/shmulcode#mimocode
```

Install everything at once:

```bash
nix profile install github:shmul95/shmulcode
# → mimocode, deepcode, grokcode, shmulcode on PATH
```

## Env file format

The env file is ordinary shell, sourced with `set -a` before `claude` starts:

```bash
export ANTHROPIC_BASE_URL="https://api.example.com/anthropic"
export ANTHROPIC_AUTH_TOKEN="…"        # or ANTHROPIC_API_KEY — exactly one
export ANTHROPIC_MODEL="some-model"    # optional
```

Required: `ANTHROPIC_BASE_URL` **plus exactly one** of `ANTHROPIC_AUTH_TOKEN` or
`ANTHROPIC_API_KEY`. Setting both is allowed but warns — Claude Code documents
that combination as an auth conflict.

Rules the wrapper enforces:

- Keep it out of git; mode `0600`. The wrapper warns (non-blocking) if the file is
  group/world-readable.
- No `set -x` / `set -v` (rejected: tracing would print your credential).
- LF line endings, no UTF-8 BOM.
- Simple `export KEY=value` lines; a failing command inside the file aborts the launch.

Default location: `${XDG_CONFIG_HOME:-$HOME/.config}/<instance>/env`.
Override with `SHMULCODE_ENV_FILE=/path/to/env`.

### Exit codes

| Code | Meaning |
|------|---------|
| `78` | wrapper-layer configuration failure (missing/unreadable env file, bad syntax, missing variables) |
| `64` | `shmulcode` usage error (unknown command/instance) |
| `73` | `shmulcode init` could not create the file (already exists, or the path/mode could not be set) |
| anything else | Claude Code's own exit code, passed through unchanged |

Diagnostics never print values — only variable *names* and which ones are set.

## Home Manager

```nix
{
  inputs.shmulcode.url = "github:shmul95/shmulcode";
  inputs.shmulcode.inputs.nixpkgs.follows = "nixpkgs";
}
```

```nix
{ inputs, config, ... }: {
  imports = [ inputs.shmulcode.homeManagerModules.default ];

  programs.shmulcode.instances.mimocode = {
    enable = true;
    envFile = config.age.secrets."mimocode-env".path;   # any path string
  };
}
```

- `envFile` is a **string**, never a Nix path — a path would copy your secret into
  the world-readable store. A `/nix/store/...` value is rejected by assertion.
- Any secret mechanism works: agenix, sops-nix, or a plain `/run/...` file. The
  module never reads the file; it bakes the path only.
- Other options per instance: `command` (rename the binary), `extraEnv`
  (non-secret defaults — credential-looking keys are rejected), `extraArgs`,
  `requiredVars`, `package`.
- `envFile = null` keeps runtime resolution (`SHMULCODE_ENV_FILE` → XDG/HOME).

## No `allowUnfree` needed

`claude-code` is unfree. The flake instantiates its own nixpkgs with a **scoped**
`allowUnfreePredicate` matching only `claude-code`, so consumers do not have to
set `allowUnfree = true` anywhere.

## Diagnostics

```bash
shmulcode list              # every instance, its env path, present/missing
shmulcode doctor mimocode   # resolution trace, file mode, variable presence
shmulcode init deepcode     # write a commented 0600 template
SHMULCODE_DEBUG=1 mimocode  # print the resolution trace before launching
```

`doctor` points you at `claude doctor` for Claude Code's own diagnostics.

## Caveats

- **`nix run …#default` does not work.** `packages.default` is a `symlinkJoin`
  with no `meta.mainProgram`; always name an instance (`#mimocode`), or use
  `nix profile install`.
- **First build is slow.** The unfree `claude-code` binary is a large download and
  is often not on the public cache; subsequent runs are cached.
- **Provider settings live in the env file**, not the flake — URL, model ids, and
  model-alias mappings are all per-provider config.
- `ANTHROPIC_BASE_URL` pointing anywhere other than `api.anthropic.com` disables
  Claude Code's Remote Control feature (by design, upstream).
- Platforms: `x86_64-linux`, `aarch64-linux`.

## Migrating from v1

v1 was a config framework (agents, skills, qrouter). It is preserved on branch
`v1` and tag `v1.0.0`. See [docs/MIGRATION.md](docs/MIGRATION.md).
