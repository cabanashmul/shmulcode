# mkLauncher: the single parameterized launcher builder.
#
# Shape of `requiredVars` (CORE-01 / ENV-05):
#   - A plain string means "this variable must be non-empty".
#   - A list of strings means "at least one of these must be non-empty".
#   Example default:
#     [ "ANTHROPIC_BASE_URL" [ "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_API_KEY" ] ]
#
# SECURITY: `envFile` is a path STRING, never a Nix path and never its contents.
# It is interpolated inside double quotes so runtime variables such as
# ${XDG_RUNTIME_DIR} expand at exec time. It is trusted consumer configuration:
# do not pass a path containing shell command substitution.
{ pkgs
, name
, envName ? name      # Resolution label; defaults to name so bare packages are unchanged.
, description ? "${name} — Claude Code against a provider env file"
, envFile ? null                     # path STRING or null; never a Nix path
, requiredVars ? [ "ANTHROPIC_BASE_URL" [ "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_API_KEY" ] ]
, extraEnv ? { }                     # non-secret defaults; env file wins
, extraArgs ? [ ]                    # fixed args; user args come after
, claudePackage ? pkgs.claude-code   # injectable so checks can use a stub
}:
let
  lib = pkgs.lib;
  resolver = import ./resolve-env-file.nix { inherit lib; };
  requiredLabels = resolver.requiredLabels requiredVars;
  commandExe = lib.getExe claudePackage;          # absolute store path (CORE-02)

  extraEnvLines = lib.concatStringsSep "\n"
    (lib.mapAttrsToList
      (k: v: "export ${lib.escapeShellArg k}=${lib.escapeShellArg v}")
      extraEnv);

  resolution = resolver.mkResolution {
    # Bare tokens: the template supplies the surrounding double quotes.
    # Passing "\"${name}\"" here renders `echo ""name": …` → SC2140 build failure.
    nameExpr = envName;
    errorLabel = envName;
    baked = if envFile == null then null else envFile;
  };
in
assert lib.assertMsg (envFile == null || (builtins.isString envFile && envFile != ""))
  "mkLauncher: envFile must be null or a non-empty path string (an empty string would silently fall back to the XDG/HOME path)";
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [ pkgs.coreutils ];          # stat only; bash is the interpreter
  meta = { inherit description; mainProgram = name; };
  text = ''
    # ---- 0. never trace (CR-02) ----
    # `SHELLOPTS=xtrace` in the ambient environment, or a `set -x` line inside
    # the env file, would echo every assignment and every value-expanding test
    # to stderr — leaking credentials. Disable unconditionally on entry.
    set +x
    set +v

    # ---- 1. resolve (override > baked > XDG/HOME) ----
    ${resolution}

    # ---- 2. existence / readability (never fall back from a baked path) ----
    if [ ! -f "$env_file" ]; then
      echo "${name}: environment file not found ($origin): $env_file" >&2
      echo "${name}: expected variables: ${lib.concatStringsSep " " requiredLabels}" >&2
      echo "${name}: run 'shmulcode init ${envName}' to create it" >&2
      exit 78
    fi
    if [ ! -r "$env_file" ]; then
      echo "${name}: environment file not readable: $env_file" >&2
      exit 78
    fi

    # ---- 3. permission warning (non-blocking, follows symlinks) ----
    mode="$(stat -L -c '%a' "$env_file" 2>/dev/null || true)"
    if [ -n "$mode" ] && (( (8#$mode & 8#077) != 0 )); then
      echo "${name}: warning: $env_file is group/world-accessible (mode $mode); chmod 600" >&2
    fi

    # ---- 3b. SHMULCODE_DEBUG trace (paths and modes only, never values) ----
    if [ -n "''${SHMULCODE_DEBUG:-}" ]; then
      echo "${name}: debug: resolved ($origin): $env_file (mode ''${mode:-unknown})" >&2
    fi

    # ---- 4. hygiene: drop ambient provider vars (compgen is absent in nixpkgs bash) ----
    for __v in "''${!ANTHROPIC_@}"; do unset -- "$__v"; done
    unset __v

    # ---- 5. non-secret defaults BEFORE the file so the file wins ----
    ${extraEnvLines}

    # ---- 6. preflight: BOM, CRLF, syntax ----
    if [[ "$(<"$env_file")" == $'\xef\xbb\xbf'* ]]; then
      echo "${name}: environment file starts with a UTF-8 BOM: $env_file" >&2
      exit 78
    fi
    if [[ "$(<"$env_file")" == *$'\r'* ]]; then
      echo "${name}: environment file contains CRLF line endings: $env_file" >&2
      exit 78
    fi
    # SECURITY (CR-02): a file that enables shell tracing would echo its own
    # assignments — including credential VALUES — to stderr. Reject it rather
    # than trying to outrace it, since `set -x` takes effect mid-file.
    if [[ "$(<"$env_file")" =~ (^|$'\n')[[:space:]]*set[[:space:]]+[-+][a-zA-Z]*[xv] ]]; then
      echo "${name}: environment file enables shell tracing; remove any 'set -x'/'set -v'" >&2
      exit 78
    fi

    # SECURITY (CR-01): discard bash's diagnostic. It echoes the offending
    # source line, which can be a line carrying a credential value.
    if ! "$BASH" -n "$env_file" 2>/dev/null; then
      echo "${name}: environment file has syntax errors: $env_file" >&2
      exit 78
    fi

    # ---- 7. source (set +u is REQUIRED to keep ENV-07 for unset refs) ----
    set +u
    set -a
    # shellcheck source=/dev/null
    if ! . "$env_file"; then
      echo "${name}: failed to load environment file: $env_file" >&2
      exit 78
    fi
    set +a
    # Re-assert strict mode: a sourced file can legitimately toggle these, and
    # the wrapper's later checks must not run under weakened options.
    set -u
    set -o errexit
    # CR-02: the env file may have run `set -x`; stop tracing before any
    # value-expanding test below (e.g. [ -z "$ANTHROPIC_AUTH_TOKEN" ]).
    set +x
    set +v

    # ---- 8. validate required variables (names only, never values) ----
    missing=()
    ${resolver.mkRequiredChecks requiredVars}
    if [ ''${#missing[@]} -ne 0 ]; then
      echo "${name}: missing required variables: ''${missing[*]}" >&2
      echo "${name}: define them in $env_file" >&2
      exit 78
    fi

    # ---- 9. documented auth conflict is non-blocking ----
    if [ -n "''${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -n "''${ANTHROPIC_API_KEY:-}" ]; then
      echo "${name}: warning: both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set; auth may not work as expected" >&2
    fi

    # ---- 10. exec must be the final statement ----
    exec ${commandExe} ${lib.escapeShellArgs extraArgs} "$@"
  '';
}
