{ lib, ... }:
let
  instances = import ./_instances.nix;
  mkLauncher = import ../lib/mk-launcher.nix;
  inherit (import ../lib/mk-instance-launchers.nix { inherit lib mkLauncher; })
    mkInstanceLaunchers;
  instanceNames = builtins.attrNames instances;
in
assert lib.assertMsg
  (builtins.all (n: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" n != null) instanceNames)
  "shmulcode: instance names must start alphanumeric and be safe shell tokens ([A-Za-z0-9][A-Za-z0-9._-]*)";
assert lib.assertMsg
  (builtins.all (n: instances.${n}.name == n) instanceNames)
  "shmulcode: each instance's name field must equal its attrset key";
assert lib.assertMsg
  (builtins.all (n: !(instances.${n} ? envFile)) instanceNames)
  "shmulcode: built-in instances must not bake an envFile; runtime resolution is the contract";
assert lib.assertMsg
  (builtins.all (n: !(builtins.elem n [ "default" "claude" "shmulcode" ])) instanceNames)
  "shmulcode: instance names must not shadow reserved package names (default, claude, shmulcode)";
{
  perSystem = { pkgs, config, ... }:
    let
      # One builder for every instance; provider differences are data only.
      # The mapping is shared with the INST-04 check so that check exercises
      # the real packaging path (see lib/mk-instance-launchers.nix).
      launchers = mkInstanceLaunchers instances pkgs pkgs.claude-code;
    in
    {
      # packages.default is the profile-install surface: the three launcher
      # binaries plus the admin command. Including pkgs.claude-code would
      # collide with a consumer's programs.claude-code and inflate the
      # profile (DIST-03). passthru.launchers keeps its Phase 3 meaning
      # (launchers only); passthru.admin exposes the admin command.
      packages = launchers // {
        default = pkgs.symlinkJoin {
          name = "shmulcode";
          paths = builtins.attrValues launchers ++ [ config.packages.shmulcode ];
          passthru.launchers = builtins.attrValues launchers;
          passthru.admin = config.packages.shmulcode;
        };
      };

      # Explicit apps: nix run resolves apps before packages, and the string
      # form is portable (flake-parts would coerce a derivation, but passing
      # lib.getExe explicitly matches the verified shape).
      apps = lib.mapAttrs
        (name: pkg: {
          type = "app";
          program = lib.getExe pkg;
          meta.description = instances.${name}.description;
        })
        launchers;
    };
}
