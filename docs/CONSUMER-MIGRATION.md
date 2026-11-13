# Consumer migration — `cabanashmul` on shmulcode v2

Status: **branch pushed, not activated.** The owner creates the secrets and runs
the activation.

## What was changed

Branch `migrate/shmulcode-v2` in `cabanashmul` (pushed; `main` untouched):

| File | Change |
|------|--------|
| `flake.nix` | `shmulcode.url = "github:shmul95/shmulcode"` with `inputs.nixpkgs.follows = "nixpkgs"` |
| `flake.lock` | input locked |
| `public/shmulcode.nix` | new: imports `inputs.shmulcode.homeManagerModules.default` and enables `mimocode`, `deepcode`, `grokcode`, each wired to `config.age.secrets."<name>-env".path` |
| `public/agenix.nix` | declares `mimocode-env`, `deepcode-env`, `grokcode-env` (mode 600) |
| `secrets/secrets.nix` | recipients for the three new `.age` files |

Notes:

- `private/{mimocode,deepcode}.nix` no longer exist in the repo (only stale
  comments referencing them remain), so nothing needed deleting — shmulcode
  replaces the launchers that used to live there.
- The three `.age` files do **not** exist yet. The branch will not *build* until
  they do; evaluation of the flake input itself is unaffected.

## Owner steps

### 1. Create the secrets

```bash
cd ~/Repositories/cabanashmul
nix run github:ryantm/agenix -- -e secrets/mimocode-env.age
nix run github:ryantm/agenix -- -e secrets/deepcode-env.age
nix run github:ryantm/agenix -- -e secrets/grokcode-env.age
```

Each file is shell, e.g. for DeepSeek:

```bash
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
export ANTHROPIC_AUTH_TOKEN="…"
export ANTHROPIC_MODEL="deepseek-flash"
export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-flash"
export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-flash"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-flash"
```

Commit the `.age` files (they are encrypted), never a plaintext env file.

### 2. Build, then switch

```bash
cd ~/Repositories/cabanashmul
git switch migrate/shmulcode-v2
home-manager build --impure     # verifies evaluation + builds the activation
home-manager switch --impure
```

> Known pre-existing issue: `nix flake check --no-build` on this repo already
> fails on `main` (a `tshmux` path error), unrelated to shmulcode. `home-manager
> build` is the meaningful gate.

### 3. Remove the `~/.local/bin/claude` shim (MIGR-03)

Once `command -v claude` resolves through a launcher (or you are happy that the
launchers exec the flake-pinned binary directly):

```bash
grep -rn 'local/bin/claude' ~/.config ~/.zshrc ~/.zshenv 2>/dev/null   # expect nothing
rm -f ~/.local/bin/claude
```

Nothing in shmulcode depends on a `claude` on `PATH` — the wrappers `exec` an
absolute store path.

### 4. Verify (MIGR-04)

```bash
shmulcode list                  # three instances, env paths, present
shmulcode doctor mimocode       # resolution trace = baked path
mimocode --version              # reaches the real claude binary
mimocode                        # TUI opens; Ctrl-C returns cleanly to the prompt
```

`doctor` should report `origin: baked path` for all three — that proves the HM
module's build-time path is in effect and the XDG fallback is not being used.

## Rolling back

```bash
git switch main
home-manager switch --impure
```

The flake input causes no changes on `main`; nothing was activated.
