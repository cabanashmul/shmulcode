# lib/hm-module.nix — Home Manager module factory.
#
# Shape: `import ./hm-module.nix { inherit nixpkgs; supportedSystems = [...]; }`
# returns a normal Home Manager module. The closure holds the FLAKE's nixpkgs,
# so consumers never need `allowUnfree` for claude-code; writeShellApplication
# and coreutils still come from the consumer's `pkgs`.
#
# This is the HM path (it runs inside the consumer's evaluation, not inside
# flake-parts' perSystem), so it instantiates the flake's nixpkgs itself with
# the SAME narrowly scoped predicate as modules/pkgs.nix. Never widen it.
#
# SECURITY: `envFile` is a path STRING only. The module never reads it, and
# no value ever crosses into the store or a derivation.
{ nixpkgs
, supportedSystems ? [ "x86_64-linux" "aarch64-linux" ]
, shmulcodePackages ? { }   # system -> packages attrset (for the admin command)
}:
{ config, lib, pkgs, ... }:
let
  mkLauncher = import ./mk-launcher.nix;
  resolver = import ./resolve-env-file.nix { inherit lib; };
  instanceData = import ../modules/_instances.nix;

  cfg = config.programs.shmulcode;
  system = pkgs.stdenv.hostPlatform.system;

  # The flake-built admin command for this system, if the factory supplied the
  # packages. It cannot see consumer-baked paths — see `installAdminCommand`.
  adminPackage = shmulcodePackages.${system}.shmulcode or null;

  # Flake-pinned claude: the only unfree allowance, exactly as in modules/pkgs.nix.
  flakePkgs =
    if builtins.elem system supportedSystems
    then import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = p: builtins.elem (lib.getName p) [ "claude-code" ];
    }
    else null;

  defaultPackage =
    if flakePkgs == null
    then throw
      "shmulcode: no flake-pinned claude-code for system \"${system}\"; supported: ${lib.concatStringsSep ", " supportedSystems}. Override programs.shmulcode.instances.<name>.package with a claude-code derivation for this system."
    else flakePkgs.claude-code;

  # Input-validation gates. Every value below is interpolated into generated
  # shell or a derivation name, so reject anything outside a strict allowlist
  # BEFORE it reaches mkLauncher (Pitfall 9).
  nameSafe = n: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" n != null;
  varSafe = v: builtins.match "[A-Za-z_][A-Za-z0-9_]*" v != null;
  # WR-03: no `~` — the baked value is double-quoted, so tilde never expands
  # and the wrapper would exit 78 with a confusing path.
  pathSafe = p: builtins.match "[A-Za-z0-9_./+{}$:@-]+" p != null;
  flatVars = vs: lib.concatMap (v: if builtins.isList v then v else [ v ]) vs;

  instanceNames = builtins.attrNames cfg.instances;
  instanceValues = builtins.attrValues cfg.instances;
  enabled = lib.filterAttrs (_: i: i.enable) cfg.instances;
  enabledValues = builtins.attrValues enabled;

  launchers = lib.mapAttrs
    (instanceName: i:
      mkLauncher {
        inherit pkgs;
        name = i.command;          # binary name + meta.mainProgram
        envName = instanceName;    # XDG/HOME segment, error labels, init hint
        envFile = i.envFile;
        requiredVars = i.requiredVars;
        extraEnv = i.extraEnv;
        extraArgs = i.extraArgs;
        claudePackage = i.package;
        description = "${i.command} — Claude Code via an env file (shmulcode)";
      })
    enabled;
in
{
  options.programs.shmulcode = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Master switch for the shmulcode Home Manager module. It is inert until
        at least one `programs.shmulcode.instances.<name>.enable` is true.
      '';
    };

    installAdminCommand = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the `shmulcode` admin command (`init`/`doctor`/`list`) alongside
        the launchers. It is the flake-built command, so it can see built-in
        instances and runtime-resolved (XDG/HOME) env files — but NOT a
        consumer's build-time baked paths. Use `SHMULCODE_DEBUG=1 <launcher>`
        to inspect a baked instance's resolution.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Install this instance's launcher. Enabling is explicit; a
              built-in name existing here never installs anything by itself.
            '';
          };

          envFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Path STRING to the shell env file, for example
              `config.age.secrets."mimocode-env".path` or
              `config.sops.secrets."mimocode-env".path`. Never a Nix path:
              a path copies the file into the world-readable store. `null`
              keeps runtime resolution (SHMULCODE_ENV_FILE > XDG/HOME).
            '';
          };

          command = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = ''
              Binary name for this launcher (defaults to the instance name).
              The env-file resolution path, error labels, and init hint keep
              using the instance name, so a rename cannot orphan the env file.
            '';
          };

          extraEnv = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Non-secret defaults exported before the env file (the file wins).";
          };

          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Fixed arguments placed before user arguments.";
          };

          requiredVars = lib.mkOption {
            type = lib.types.listOf (lib.types.either lib.types.str (lib.types.listOf lib.types.str));
            default = resolver.defaultRequiredVars;
            description = ''
              Required variables. A string must be non-empty; a list means at
              least one member must be non-empty.
            '';
          };

          package = lib.mkOption {
            type = lib.types.package;
            default = defaultPackage;
            description = ''
              The claude-code derivation to exec. Defaults to the
              flake-pinned claude-code for this system; override on an
              unsupported system or to pin a different build.
            '';
          };
        };
      }));
      # Discoverability only. An attrsOf default is discarded as soon as the
      # user defines ANY instance (Pitfall 1: module-system priority filtering),
      # so the built-in ergonomics come from the submodule defaults above, not
      # from this attrset. Never rely on this merging with user definitions.
      default = lib.mapAttrs (_: _: { enable = false; }) instanceData;
      description = ''
        Per-instance launchers. Built-in names (mimocode, deepcode, grokcode)
        are discoverable defaults with `enable = false`; enabling is explicit.
        Defining one instance replaces this default attrset, so the per-instance
        submodule defaults (command, requiredVars, package) fill the rest.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = builtins.attrValues launchers
      ++ lib.optional (cfg.installAdminCommand && adminPackage != null) adminPackage;

    assertions = [
      {
        # WR-02: check for a store path ANYWHERE in the string, not just as a
        # prefix (`//nix/store/...` and mid-string paths previously slipped by).
        # Belt-and-braces: a Nix path literal is already copied into the store
        # before this runs — this only catches store-path strings, so always
        # pass a string path, never a path literal.
        assertion = builtins.all
          (i: i.envFile == null || !(lib.hasInfix "/nix/store/" i.envFile))
          instanceValues;
        message = "programs.shmulcode: envFile must not reference /nix/store — that is a copy of a secret in the world-readable store; pass the runtime path (e.g. config.age.secrets.<n>.path) instead";
      }
      {
        # WR-01: extraEnv is baked into the world-readable store, so it must
        # never carry a credential. Reject obviously secret-bearing keys.
        assertion = builtins.all
          (i: builtins.all
            (k: builtins.match ".*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL).*" (lib.toUpper k) == null)
            (builtins.attrNames i.extraEnv))
          instanceValues;
        message = "programs.shmulcode: extraEnv is baked into the Nix store and must not hold credentials — remove any *KEY*/*TOKEN*/*SECRET*/*PASSWORD* entry and put it in the env file instead";
      }
      {
        # WR-04: an empty any-of group renders invalid bash (`if ; then`).
        assertion = builtins.all
          (i: builtins.all
            (g: !(builtins.isList g) || builtins.length g > 0)
            i.requiredVars)
          instanceValues;
        message = "programs.shmulcode: requiredVars any-of groups must not be empty lists";
      }
      {
        assertion = builtins.all
          (i: i.envFile == null || i.envFile != "")
          instanceValues;
        message = "programs.shmulcode: envFile must not be the empty string (it would silently fall back to the XDG/HOME path); use null for runtime resolution";
      }
      {
        assertion = builtins.all
          (n: nameSafe n && nameSafe cfg.instances.${n}.command)
          instanceNames;
        message = "programs.shmulcode: instance names and command must match [A-Za-z0-9][A-Za-z0-9._-]*";
      }
      {
        assertion = builtins.all
          (i: builtins.all varSafe (flatVars i.requiredVars))
          instanceValues;
        message = "programs.shmulcode: requiredVars entries must be shell variable names ([A-Za-z_][A-Za-z0-9_]*)";
      }
      {
        assertion = builtins.all
          (i: i.envFile == null || pathSafe i.envFile)
          instanceValues;
        message = "programs.shmulcode: envFile may contain only [A-Za-z0-9_./+{}$:@-]; no spaces, quotes, command substitution, or ~ (a tilde is never expanded in the baked path)";
      }
      {
        assertion =
          let cmds = map (i: i.command) enabledValues;
          in builtins.length cmds == builtins.length (lib.unique cmds);
        message = "programs.shmulcode: enabled instance commands must be unique (bin/<command> collisions break home.packages)";
      }
      {
        assertion = builtins.all
          (i: !(builtins.elem i.command [ "claude" "shmulcode" "default" ]))
          instanceValues;
        message = "programs.shmulcode: command must not be a reserved name (claude, shmulcode, default)";
      }
    ];
  };
}
