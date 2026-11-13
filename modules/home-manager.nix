# Flake outputs: the flake-pinned Home Manager module.
#
# `nix flake check` warns "unknown flake output 'homeManagerModules'" on
# Nix 2.34.7. The warning is cosmetic (the output evaluates and is usable);
# `flake.homeModules` is a recognized output and is exported as an alias for
# consumers using Home Manager's own flake-parts module. Do not delete either
# output to silence the warning.
{ inputs, config, ... }:
let
  # Factory wrapped with the FLAKE's nixpkgs so consumers need no allowUnfree.
  # supportedSystems is DERIVED from the flake's own `systems` list — do not
  # hardcode it here or in checks.nix or the two drift when flake.nix changes.
  hmModule = import ../lib/hm-module.nix {
    inherit (inputs) nixpkgs;
    supportedSystems = config.systems;
    # Lets the module install the `shmulcode` admin command for consumers.
    # It is the flake-built command: it sees built-ins and runtime-resolved
    # paths, not a consumer's build-time baked paths (use SHMULCODE_DEBUG).
    shmulcodePackages = inputs.self.packages;
  };
in
{
  flake.homeManagerModules.default = hmModule;
  flake.homeModules.default = hmModule;
}
