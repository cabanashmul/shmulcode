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
, description ? "${name} — Claude Code against a provider env file"
, envFile ? null                     # path STRING or null; never a Nix path
, requiredVars ? [ "ANTHROPIC_BASE_URL" [ "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_API_KEY" ] ]
, extraEnv ? { }                     # non-secret defaults; env file wins
, extraArgs ? [ ]                    # fixed args; user args come after
, claudePackage ? pkgs.claude-code   # injectable so checks can use a stub
}:
let
  lib = pkgs.lib;
  commandExe = lib.getExe claudePackage;          # absolute store path (CORE-02)
  baked = if envFile == null then "" else envFile;

  requiredNames = map
    (g: if builtins.isList g then lib.concatStringsSep "/" g else g)
    requiredVars;

  groupCheck = g:
    if builtins.isList g then
      let
        cond = lib.concatMapStringsSep " && " (v: "[ -z \"\${${v}:-}\" ]") g;
        label = lib.concatStringsSep "/" g;
      in "if ${cond}; then missing+=(\"${label}\"); fi"
    else
      "if [ -z \"\${${g}:-}\" ]; then missing+=(\"${g}\"); fi";

  extraEnvLines = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") extraEnv);

  resolution = if baked == "" then ''
    if [ -n "''${SHMULCODE_ENV_FILE:-}" ]; then
      env_file="$SHMULCODE_ENV_FILE"; origin="SHMULCODE_ENV_FILE override"
    elif [ -n "''${XDG_CONFIG_HOME:-}" ]; then
      env_file="''${XDG_CONFIG_HOME}/${name}/env"; origin="default path"
    elif [ -n "''${HOME:-}" ]; then
      env_file="$HOME/.config/${name}/env"; origin="default path"
    else
      echo "${name}: neither XDG_CONFIG_HOME nor HOME is set; set SHMULCODE_ENV_FILE" >&2
      exit 78
    fi
  '' else ''
    if [ -n "''${SHMULCODE_ENV_FILE:-}" ]; then
      env_file="$SHMULCODE_ENV_FILE"; origin="SHMULCODE_ENV_FILE override"
    else
      env_file="${baked}"; origin="baked path"
    fi
  '';
in
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [ pkgs.coreutils ];          # stat only; bash is the interpreter
  meta = { inherit description; mainProgram = name; };
  text = ''
    # ---- 1. resolve (override > baked > XDG/HOME) ----
    ${resolution}

    # ---- 2. existence / readability (never fall back from a baked path) ----
    if [ ! -f "$env_file" ]; then
      echo "${name}: environment file not found ($origin): $env_file" >&2
      echo "${name}: expected variables: ${lib.concatStringsSep " " requiredNames}" >&2
      echo "${name}: run 'shmulcode init ${name}' to create it" >&2
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
    if ! "$BASH" -n "$env_file"; then
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
    set -u

    # ---- 8. validate required variables (names only, never values) ----
    missing=()
    ${lib.concatMapStringsSep "\n" groupCheck requiredVars}
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
