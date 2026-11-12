# lib/resolve-env-file.nix
#
# Single source of truth for env-file resolution and required-variable checks.
# `lib/mk-launcher.nix` (runtime wrapper) and `modules/admin.nix` (doctor/list)
# both interpolate these fragments, so `doctor` cannot drift from what the
# wrapper actually does.
#
# SECURITY: these fragments print names and paths only. They must never
# interpolate a variable's value into a message (SEC-03).
{ lib }:
let
  defaultRequiredVars = [ "ANTHROPIC_BASE_URL" [ "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_API_KEY" ] ];

  label = g: if builtins.isList g then lib.concatStringsSep "/" g else g;
in
rec {
  inherit defaultRequiredVars;

  # Human-readable labels for each requirement, e.g. ["ANTHROPIC_BASE_URL"
  # "ANTHROPIC_AUTH_TOKEN/ANTHROPIC_API_KEY"].
  requiredLabels = requiredVars: map label requiredVars;

  # bash that appends the NAME of every unmet requirement to `missing`.
  # Caller must declare `missing=()` first. Values are never read into a message.
  mkRequiredChecks = requiredVars:
    lib.concatMapStringsSep "\n"
      (g:
        if builtins.isList g then
          let
            cond = lib.concatMapStringsSep " && " (v: "[ -z \"\${${v}:-}\" ]") g;
            lab = lib.concatStringsSep "/" g;
          in "if ${cond}; then missing+=(\"${lab}\"); fi"
        else
          "if [ -z \"\${${g}:-}\" ]; then missing+=(\"${g}\"); fi")
      requiredVars;

  # bash that SETS `env_file` and `origin`.
  #   nameExpr   shell fragment for the instance-name path segment
  #   errorLabel shell fragment for the no-HOME/XDG message prefix
  #   baked      nix-level baked path string, or null
  #
  # nameExpr/errorLabel are interpolated INSIDE double quotes by the template,
  # so callers pass a BARE shell token with no quote characters of its own.
  # Passing a value that already carries quotes renders `""name": …` and fails
  # shellcheck (SC2140/SC2027), which fails the whole build.
  mkResolution = { nameExpr, errorLabel, baked ? null }:
    if baked == null || baked == "" then ''
      if [ -n "''${SHMULCODE_ENV_FILE:-}" ]; then
        env_file="$SHMULCODE_ENV_FILE"; origin="SHMULCODE_ENV_FILE override"
      elif [ -n "''${XDG_CONFIG_HOME:-}" ]; then
        env_file="''${XDG_CONFIG_HOME}/${nameExpr}/env"; origin="default path (XDG_CONFIG_HOME)"
      elif [ -n "''${HOME:-}" ]; then
        env_file="$HOME/.config/${nameExpr}/env"; origin="default path (HOME)"
      else
        echo "${errorLabel}: neither XDG_CONFIG_HOME nor HOME is set; set SHMULCODE_ENV_FILE" >&2
        exit 78
      fi
    '' else ''
      if [ -n "''${SHMULCODE_ENV_FILE:-}" ]; then
        env_file="$SHMULCODE_ENV_FILE"; origin="SHMULCODE_ENV_FILE override"
      else
        # CR-02: baked paths may reference runtime variables (e.g.
        # ''${XDG_RUNTIME_DIR}/agenix/x.env). Expand under set +u so an unset
        # variable degrades to an empty segment and the normal missing-file
        # path reports it at exit 78 instead of nounset aborting at exit 1.
        set +u
        env_file="${baked}"; origin="baked path"
        set -u
      fi
    '';
}
