<!-- GSD:project-start source:PROJECT.md -->
## Project

**shmulcode**

A Nix flake that packages provider-multiplexed Claude Code launchers. One parameterized wrapper core yields `mimocode`, `deepcode`, and `grokcode` — each sources its provider's env file (`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, …) and execs Claude Code, which the flake supplies. It serves the owner directly (across their own machines) and anyone who wants "just run my agent against provider X" without hand-wiring wrappers and secrets.

**Core Value:** One trustworthy command per provider — the only difference between providers is the env file.

### Constraints

- **Tech stack:** Nix flakes; `claude-code` from the flake's pinned nixpkgs.
- **Security:** provider secrets never appear in the flake, store, or derivation inputs — only paths are referenced; env files are sourced at runtime. Module-baked paths point at the consumer's decrypted secret.
- **Compatibility:** module must not assume agenix; any file-providing secret mechanism works.
- **Distribution:** public flake, consumable via `nix run github:shmul95/shmulcode#<instance>` with no local config.
- **Breaking changes:** acceptable — no third-party users yet (owner on multiple machines).
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version (verified 2026-11-05) | Purpose | Why Recommended |
|------------|-------------------------------|---------|-----------------|
| Nix + flakes | Nix 2.34.7 (tested locally) | Build, distribute, run | The product *is* a flake. No impure evaluation is needed: nothing reads `$USER`/`$HOME` at eval time; the runtime fallback path is computed in bash. `nix run github:...#mimocode` must work without `--impure`. **HIGH** |
| `nixpkgs` (nixos-unstable) | Pinned in `flake.lock`; supplies `claude-code` 2.1.201 in the local pin (upstream master had **2.1.318**, built 2026-11-03) | Package source | The only supported source of the `claude` binary in-scope. Keep its own pin rather than `nixpkgs.follows` so `nix run` and the HM module always have a `claude-code` that exists. **HIGH** |
| `flake-parts` | rev `ea2630b…` (2026-11-01) | Flake output structure | Matches the `cabanashmul`/`shmul*` ecosystem convention (`PROJECT.md` explicitly names flake-parts + import-tree). Provides `perSystem`, lazy `packages.<system>`, and a clean place to override `pkgs`. **HIGH** |
| `import-tree` | rev `eb1b52e…` (2026-09-03) | Auto-import modules from a directory | Dendritic layout already used by `cabanashmul` and `DivitMittal/ai-nixCfg`. **Caution:** the current API is a callable module, not an object with `.imports` (see Recommended Flake Layout and What NOT to Use). **HIGH** |
| `writeShellApplication` | nixpkgs trivial builder | Build each launcher | Bash + strict mode + build-time shellcheck + `runtimeInputs` on `PATH` + `meta.mainProgram = name` set automatically. Exactly fits a wrapper that has real logic (resolution, warnings, validation). **HIGH** |
| `symlinkJoin` | nixpkgs | `packages.default` bundle | One install yields all launcher binaries on `PATH`. Verified: it is *not* runnable via `nix run ...#default` (no `meta.mainProgram`); that is acceptable. **HIGH** |
| `claude-code` | 2.1.201 (local pin) | The wrapped binary | `pkgs.claude-code`; unfree; `meta.mainProgram = "claude"`; prebuilt binary wrapped with `DISABLE_AUTOUPDATER=1` and its own `PATH`. **HIGH** |
| Home Manager | Consumer's HM (`programs.claude-code` exists in master) | Module host | The module is plain HM options; it does **not** need a `home-manager` flake input or HM library functions. **HIGH** |
### Supporting Libraries
| Library | Purpose | When to Use |
|---------|---------|-------------|
| `pkgs.coreutils` (`stat -L -c %a`) | Symlink-aware permission check on the env file | Every launcher. Add to `runtimeInputs`. **HIGH** |
| `lib.escapeShellArg` | Safely embed names/paths in generated bash | Any value interpolated into the script (names, baked env path). Single-quotes and escapes `'`. **HIGH** |
| `lib.getExe` | Absolute path to the wrapped binary | `exec ${lib.getExe claudePackage} "$@"`; avoids PATH dependence. **HIGH** |
| `lib.getName` | Match the unfree package in `allowUnfreePredicate` | `builtins.elem (lib.getName pkg) [ "claude-code" ]`. **HIGH** |
| `lib.mapAttrsToList` / `lib.filterAttrs` | Turn the instance attrset into `home.packages` | HM module. **HIGH** |
| agenix / sops-nix | Not dependencies — consumer secret providers | The module accepts any *string path*; these are the common producers of that path. **HIGH** |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| `nix build .#mimocode` / `nix flake check` | Validation | `nix build` builds the unfree `claude-code`; `nix flake check` evaluates outputs. Both pass without `NIXPKGS_ALLOW_UNFREE` because the flake owns a `pkgs` with a scoped `allowUnfreePredicate` (verified). |
| `shellcheck` | Runs automatically inside `writeShellApplication` | Any warning fails the build. The dynamic `.` requires `# shellcheck source=/dev/null` (verified: omitting it fails with SC1090). |
| `nixfmt` / `treefmt-nix` | Formatting | Optional; ecosystem-standard. |
| `deadnix` / `statix` | Lint | Optional. |
## Recommended Flake Layout
## Packages, Apps, and `nix run` Resolution
## Package Selection: `writeShellApplication` (not `writeScriptBin`/`writeShellScriptBin`)
- Shebang is nixpkgs bash; it prepends `set -o errexit`, `set -o nounset`, `set -o pipefail`.
- It prepends `runtimeInputs` to `PATH` and **retains the inherited `PATH`** (`inheritPath = true` by default). Retaining it is essential: Claude Code spawns Bash tool subprocesses that need the user's tools. Do not disable it.
- It runs shellcheck in `checkPhase`; warnings fail the build.
- It sets `meta.mainProgram = name`.
- `runtimeInputs` includes `claude-code`, so `claude` is also first on the wrapper's `PATH` for any self-spawn, while `exec` uses an absolute path.
- `writeShellScriptBin`: no shellcheck, no strict mode, no `runtimeInputs`; you would hand-roll all three.
- `writeScriptBin`: no bash-specific guarantees and no checks; not suitable.
- `makeWrapper`/`wrapProgram` alone: only prepends env/flags to an existing binary. The launcher needs file resolution, permission warnings, sourcing, and validation — a script is required. (`makeWrapper` is used *by* `writeShellApplication` internally; no need to call it.)
## Verified Launcher Script Contract
- `# shellcheck source=/dev/null` is **mandatory**. Without it, `writeShellApplication` fails at build time with `SC1090 (warning): ShellCheck can't follow non-constant source`.
- `if ! . "$file"` is deliberate. Bare `. "$file"` under `set -o errexit` exits before your error message; `if !` keeps the failure reportable. Verified: broken env → own message + exit 78.
- `${VAR:-}` is mandatory under `set -o nounset`.
- Env hygiene is not cosmetic: on this machine an ambient `ANTHROPIC_API_KEY` made a file missing a credential pass validation until the test was rerun with `env -u ANTHROPIC_API_KEY` (verified).
- Source the file with POSIX `.`, not `source`, and do not pipe it (`cat file | ...`) — values must be exported into this process, and `set -a` exports assignments made by the sourced file.
- Env files are executable shell by contract. Document that they must be simple `export KEY=value` lines: under `errexit`, a failing command inside the file aborts the launcher.
- `stat -L -c '%a'` is GNU coreutils; add `pkgs.coreutils` to `runtimeInputs`. `-L` is what catches an agenix/sops symlink pointing at a 0644 target (verified).
- Exit code 78 (`EX_CONFIG`) distinguishes wrapper-layer failures from Claude's own exit codes. `exec` preserves Claude's exit code, signals, and TTY.
## `claude-code` in nixpkgs (verified facts)
- Attribute: `pkgs.claude-code`; `pname`/name `claude-code`; `meta.mainProgram = "claude"`.
- Version in the local nixpkgs pin: **2.1.201**; upstream nixpkgs master manifest: **2.1.318** (`buildDate 2026-11-03`). Version tracks the nixpkgs input; a newer version means `nix flake update nixpkgs`.
- License: `lib.licenses.unfree`; `meta.unfree = true`; `sourceProvenance = [ binaryNativeCode ]`.
- Platform list (master): `aarch64-darwin`, `aarch64-linux`, `x86_64-linux` (the local pin also listed `x86_64-darwin`).
- Packaging: `fetchurl` of a zstd-compressed prebuilt binary from `downloads.claude.ai`, `dontUnpack`, `autoPatchelfHook` on Linux, then `wrapProgram` sets:
- Because it is unfree, the flake must instantiate its own `pkgs` with a scoped predicate. Verified working while the machine's global Nix config does **not** allow unfree:
- Do not special-case the binary's own wrapper env vars; the nixpkgs wrapper owns them (`--set` wins over the env file for the ones it sets). **HIGH**
## Home Manager Module Contract
- **`envFile` must be `types.str`, never `types.path`.** A `path`-typed option (or a path literal interpolated into a string) is copied into the Nix store at evaluation time — which would put the API keys in the world-readable store. A string such as `config.age.secrets."mimocode-env".path` (`/run/agenix/...`) is not read or copied. Add the store-prefix assertion above as a second line of defence. **HIGH**
- The path may not exist at build/eval time (agenix decrypts at activation). That is fine: only the string is embedded.
- The wrapper is built with the **consumer's** `pkgs.writeShellApplication` (bash/coreutils), but execs the **flake-pinned** `claude-code`. This keeps the module working without requiring consumers to set `allowUnfree`, and avoids depending on the consumer's nixpkgs having `claude-code`. Tradeoff: bash/coreutils come from the consumer's nixpkgs while the binary comes from the flake's pin, so the closure can contain two nixpkgs' coreutils; acceptable because `claude-code` is a prebuilt FOD. **MEDIUM-HIGH**
- Use only long-stable `writeShellApplication` arguments (`name`, `text`, `runtimeInputs`, `meta`) in the module path: the consumer's nixpkgs may predate newer options such as `runtimeEnv`/`inheritPath`. **HIGH**
- Default `instances` to the flake's three built-ins with `envFile = null`, so enabling the module reproduces the bare-install behaviour; users override per instance. If you prefer opt-in, default to `{}` instead — pick one and document it. **MEDIUM**
- Do **not** put provider vars in `home.sessionVariables`; that leaks one provider's routing into every `claude` invocation in the session. Env-file sourcing per process is the contract. **HIGH**
- Do not install `claude-code` via `home.packages` unless `installClaude` is set; the wrappers already carry it in their closures and a bare `claude` may collide with `programs.claude-code`. **HIGH**
- Export the module under `flake.homeManagerModules.default` (required for `cabanashmul`'s builder and matching agenix). Optionally also alias `flake.homeModules.default` for consumers using Home Manager's own flake-parts module, which defines `flake.homeModules`. Both are freeform flake attributes; the prototype confirmed `flake.homeManagerModules` evaluates. **MEDIUM-HIGH**
## Claude Code Provider Env Contract (official docs)
| Variable | Documented behaviour | Use in shmulcode |
|----------|----------------------|------------------|
| `ANTHROPIC_BASE_URL` | Overrides the API endpoint (proxy/gateway). Remote Control is disabled when it is not `api.anthropic.com` (v2.1.196+). | **Required**; the provider selector. |
| `ANTHROPIC_AUTH_TOKEN` | Custom `Authorization` header value, sent as `Bearer <value>`. Takes precedence over a saved login immediately. | Accepted credential; preferred when the gateway calls it a bearer token. |
| `ANTHROPIC_API_KEY` | Sent as `X-Api-Key`; overrides a subscription, but in interactive mode requires a one-time approval; a declined key is ignored. | Accepted credential. Accept **either**, never require both. If both are set, docs warn about an auth conflict. |
| `ANTHROPIC_MODEL` | Model used at startup; `--model` and `/model` override it; it overrides the `model` settings key. | Optional; set per provider in the env file. |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Model ID the `sonnet` alias resolves to; used by `opusplan` outside Plan Mode. | Optional alias pin. |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Model ID the `opus` alias resolves to; used by `opusplan` in Plan Mode. | Optional alias pin. |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Model ID the `haiku` alias resolves to; also background functionality. | Preferred replacement for the deprecated variable. |
| `ANTHROPIC_DEFAULT_FABLE_MODEL` | Model ID the `fable` alias resolves to. | Optional/newer. |
| `ANTHROPIC_DEFAULT_MODEL` | Default model for new sessions when no file sets `model`. | Optional. |
| `ANTHROPIC_SMALL_FAST_MODEL` | **Deprecated** Haiku-class model for background tasks. | Do not emit; support only if reading legacy env files. |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Default model for subagents/teammates; per-invocation or definition `model` wins. | Optional. |
| `ANTHROPIC_CUSTOM_HEADERS` | Extra headers, `Name: Value`, newline-separated. | Optional for gateways needing routing/tenant headers. |
| `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` | Populates `/model` from the gateway's `/v1/models`. | Optional quality-of-life; off by default. |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | Disables telemetry/version checks etc.; also disables auto-updates and fast-mode checks. | Optional; nixpkgs already disables the updater. Not on by default (it also disables the fast-mode availability check and affects telemetry-dependent features). |
| `DISABLE_AUTOUPDATER` | Already set to `1` by the nixpkgs wrapper. | Do not duplicate. |
| `CLAUDE_CONFIG_DIR` | **Real.** Overrides config dir (default `~/.claude`): settings, session history, plugins. Documented for "running multiple accounts side by side"; ignored in project/local settings; HM's `programs.claude-code` exports it when non-default. | **Do not set by default.** Sharing history/settings across providers is desirable. Provide pass-through (env file or ambient) for users who want per-provider isolation. |
- Providers differ in which header they read. Requiring `ANTHROPIC_BASE_URL` + one of the two credential variables is correct; accepting both without warning risks the documented "auth may not work as expected" conflict. **HIGH**
- Model alias variables are provider-agnostic from Claude Code's perspective; a provider that only serves one model can set `ANTHROPIC_MODEL` and map all three default aliases to it to avoid 404s in the `/model` picker. **MEDIUM**
- `nixpkgs`' wrapper already forces `USE_BUILTIN_RIPGREP=0`, `DISABLE_AUTOUPDATER=1`; do not try to override these from the env file (the wrapper's `--set` wins). **HIGH**
## Installation
# Single launcher; args after -- go to claude
# All launchers on PATH (packages.default = symlinkJoin)
# Single launcher into the profile
# Development
# No nixpkgs.follows by default: the flake must own a nixpkgs that has claude-code.
# (PROJECT.md notes follows as the ecosystem convention; follows is fine only if the
# consumer ensures their nixpkgs contains claude-code and wants closure sharing.)
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `writeShellApplication` | `writeShellScriptBin` | Only if a shellcheck false positive cannot be suppressed; you then lose strict mode, `runtimeInputs`, and `mainProgram` and must add them manually. |
| `writeShellApplication` | `makeWrapper` + `symlinkJoin` | Only for pure "set env/flags around an existing binary" wrappers with no resolution logic. Not sufficient here. |
| `writeShellApplication` | `wrapper-manager` or `nix-wrapper-modules` | If launchers become "fat" (state dirs, config seeding, services). These expose `makeWrapper` through the module system and compose well, at the cost of an extra input and abstraction. Defer per `PROJECT.md`. |
| Packages only (no `apps`) | Explicit `apps.<system>.<name>` | Only if an app must run something other than `meta.mainProgram`, or if tooling requires `apps` output. Otherwise duplicated. |
| Flake-pinned `claude-code` in the HM module | Consumer's `pkgs.claude-code` | If the consumer already enforces `allowUnfree` and wants a single nixpkgs closure; then add a `package` option and document the requirement. |
| `nixpkgs` `claude-code` | `numtide/llm-agents.nix` | If nixpkgs version lag becomes a problem; it updates daily, but adds an input/overlay and still needs unfree handling. |
| Attrs of submodules (`instances.<name>`) | `listOf submodule` | Only if order matters; it does not here, and a list makes per-instance overrides awkward. |
| `types.str` env path + assertion | `types.path` | Never for secrets. `types.path` copies the file into the Nix store. |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `types.path` for `envFile` (or a path literal like `./secrets/env`) | Nix copies the file into `/nix/store`; API keys become world-readable | `types.str`, e.g. `config.age.secrets."x".path`, plus the store-prefix assertion |
| `builtins.readFile` / `pkgs.writeText` for env contents | Bakes secrets into the store/derivation | Read/source at runtime only |
| `command -v claude` / PATH lookup | Old wrapper bug: fails or picks an unintended binary | `lib.getExe claudePackage` (absolute store path) |
| `source "$file"` | Non-POSIX; shellcheck noise | POSIX `. "$file"` with `# shellcheck source=/dev/null` |
| Bare `. "$file"` under `set -e` | Aborts with no self-describing message | `if ! . "$file"; then ... exit 78; fi` |
| `set +u` around the whole script | Hides genuine unset-variable bugs | Keep `nounset`; use `${VAR:-}` |
| `home.sessionVariables.ANTHROPIC_*` | Leaks one provider into all sessions/processes | Per-process env file sourcing |
| Global `allowUnfree = true` in the flake | Wider than necessary; surprises consumers | `allowUnfreePredicate` for `claude-code` only |
| `(import-tree ./dir).imports` with a fresh import-tree | API changed; verified eval failure | `imports = [ (import-tree ./dir) ];` |
| Library/data `.nix` files inside the import-tree root without `_` | import-tree imports them as modules and they fail to evaluate | `_name.nix` or a separate `lib/` imported explicitly |
| Advertising `nix run github:...#` (no instance) | `packages.default` is a `symlinkJoin` with no `mainProgram`; fails at exec | Always name an instance, or define a real `apps.default` later |
| `--impure` in the published flake | Unnecessary here; breaks `nix run` ergonomics | Runtime `$HOME`/`$XDG_CONFIG_HOME` in bash; no eval-time env reads |
| Rewriting `~/.claude/settings.json` | Clobbers user config, uninstall pain (see FEATURES anti-features) | Env-file injection only |
## Stack Patterns by Variant
- `envFile = config.age.secrets."<name>-env".path` or `config.sops.secrets."...".path`.
- Both are runtime paths under `/run`; no store copy. agenix `mode = "600"` avoids the permission warning.
- `envFile = null`; wrapper falls back to `${XDG_CONFIG_HOME:-$HOME/.config}/<name>/env`.
- Warn on group/other bits; error names the required variables.
- Use `ANTHROPIC_AUTH_TOKEN`; avoids the interactive approval prompt that `ANTHROPIC_API_KEY` triggers. If the provider only documents `x-api-key`, use `ANTHROPIC_API_KEY` and document the one-time approval.
- Set `ANTHROPIC_MODEL` and map `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` to it; consider `CLAUDE_CODE_SUBAGENT_MODEL` as well, and enable `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` if the gateway implements `/v1/models`.
- Set `CLAUDE_CONFIG_DIR` in the env file (documented multi-account mechanism). Do not set it by default.
- Keep `mkLauncher` as the single entry point and extend its argument set (`preExec`, `extraRuntimeInputs`, `stateDir`, `files`), or migrate to `wrapper-manager`/`nix-wrapper-modules`. The flake outputs (`packages.<system>.<name>` + `homeManagerModules.default`) stay the same.
- Add `aarch64-darwin`/`x86_64-darwin` to `systems`. `stat` comes from nixpkgs `coreutils`, so `-c`/`-L` remain available; bash comes from nixpkgs. `claude-code` supports darwin.
## Testing the Wrapper Without Downloading Claude
## Roadmap Implications
- **Phase 1 (flake skeleton + builder):** flake-parts/import-tree layout, `allowUnfreePredicate`, `mkLauncher`, per-instance packages, `symlinkJoin` default. Done when `nix build .#mimocode` evaluates and `nix run .#mimocode -- --version` reaches a stub/real claude.
- **Phase 2 (runtime contract):** env resolution, hygiene, sourcing, permission warning, missing-variable error, exit 78; add checks with a stub claude.
- **Phase 3 (Home Manager module):** `programs.shmulcode.instances` submodules, `types.str` env paths, store-prefix assertion, flake-pinned claude, `homeManagerModules.default`; consume it from `cabanashmul` replacing `private/{mimocode,deepcode}.nix`.
- **Phase 4 (docs + distribution):** the `--` passthrough, `nix profile install` default bundle, env-file format, `CLAUDE_CONFIG_DIR` opt-in, and the `nix run` no-instance caveat.
## Version Compatibility
| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| `writeShellApplication` (nixpkgs pin) | Nix 2.34.7 | Verified generated script and `meta.mainProgram`. |
| `claude-code` 2.1.201 (nixpkgs pin) | `x86_64-linux`, `aarch64-linux` (flake systems) | Binary FOD; unfree predicate required. |
| Nixpkgs master `claude-code` 2.1.318 | Same flake structure | Version moves with `nix flake update nixpkgs`; no code change. |
| `import-tree` rev `eb1b52e…` | `imports = [ (import-tree ./nix) ]` | Older revs (e.g. `c41e7d5…` used by `cabanashmul`) accepted `.imports`; do not mix idioms. |
| `flake-parts` rev `ea2630b…` | `perSystem._module.args.pkgs` override | Verified; no flake-parts nixpkgs option needed. |
| HM module (uses consumer `writeShellApplication`) | Older nixpkgs consumers | Limit args to `name`/`text`/`runtimeInputs`/`meta`; avoid `runtimeEnv`/`inheritPath`. |
| Claude Code ≥ 2.1.196 | `ANTHROPIC_BASE_URL` gateways | Remote Control disabled on non-Anthropic hosts; don't promise it. |
| Claude Code ≥ 2.1.227 | `ANTHROPIC_CUSTOM_HEADERS` validation | Older versions accept it but with looser checks. |
| `ANTHROPIC_SMALL_FAST_MODEL` | Deprecated | Use `ANTHROPIC_DEFAULT_HAIKU_MODEL`. |
## Sources
- Local nixpkgs evaluation (2026-11-05): `nix eval nixpkgs#claude-code.version` → `2.1.201`; `meta.license` unfree; `meta.mainProgram` `claude`; `allowUnfreePredicate` eval succeeds while global config disallows unfree. **HIGH**
- nixpkgs `claude-code` package source: https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/cl/claude-code/package.nix (fetched 2026-11-05; upstream manifest 2.1.318, buildDate 2026-11-03). **HIGH**
- nixpkgs `writeShellApplication` implementation: https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/trivial-builders/default.nix (fetched 2026-11-05; strict mode, `runtimeInputs`, shellcheck checkPhase, `inheritPath`). Local build confirmed generated script and `meta.mainProgram`. **HIGH**
- Nix manual, `nix run`: https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-run (apps → packages → legacyPackages; `meta.mainProgram` → `pname` → `name`). **HIGH**
- import-tree README and source: https://github.com/vic/import-tree (fetched 2026-11-05; default filter ignores `/_` and non-`.nix`; current revision is a callable module). Local prototype confirmed the `.imports` API break and the working form. **HIGH**
- flake-parts options: https://flake.parts/options/flake-parts.html (`flake.packages`, `flake.apps`, perSystem). **HIGH**
- Claude Code environment variables: https://code.claude.com/docs/en/env-vars (fetched 2026-11-05; `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, model aliases, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_SUBAGENT_MODEL`, deprecation of `ANTHROPIC_SMALL_FAST_MODEL`). **HIGH**
- Claude Code settings/model config: https://code.claude.com/docs/en/settings and https://code.claude.com/docs/en/model-config (env-var precedence, alias resolution, `ANTHROPIC_MODEL` vs `--model`). **HIGH**
- Claude Code LLM gateway connection: https://code.claude.com/docs/en/llm-gateway-connect (credential-to-header mapping, auth-conflict warning, `ANTHROPIC_CUSTOM_HEADERS`, gateway model discovery). **HIGH**
- Home Manager `programs.claude-code`: https://github.com/nix-community/home-manager/blob/master/modules/programs/claude-code/default.nix and `options.nix` (fetched 2026-11-05; `package`, `settings`, `configDir`, exports `CLAUDE_CONFIG_DIR` when non-default). **HIGH**
- agenix flake exports: https://github.com/ryantm/agenix/blob/master/flake.nix (`homeManagerModules.default` convention). **HIGH**
- Local `cabanashmul` flake and wrappers (`private/mimocode.nix`, `private/deepcode.nix`, `public/_builder.nix`): existing `writeShellApplication` + `.env` sourcing shape; builder exports `homeManagerModules.default` and passes `extraSpecialArgs`. **HIGH**
- DivitMittal/ai-nixCfg: https://github.com/DivitMittal/ai-nixCfg (flake-parts + import-tree, `flake.homeManagerModules.*`, per-tool HM modules). **MEDIUM**
- numtide/llm-agents.nix: https://github.com/numtide/llm-agents.nix (claude-code package, unfree, daily updates, overlay; no HM module). **MEDIUM**
- nix-wrapper-modules: https://github.com/BirdeeHub/nix-wrapper-modules (module-system wrappers, alternative for fat launchers). **MEDIUM**
- wrapper-manager: https://github.com/viperML/wrapper-manager (module-system `makeWrapper`/`symlinkJoin`; repository migrating to Codeberg; README fetch failed, details from project documentation/search). **MEDIUM**
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
