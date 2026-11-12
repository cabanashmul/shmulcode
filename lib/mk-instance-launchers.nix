# The single instance → launcher mapping.
#
# SECURITY / CORE-01 + INST-04: this is the ONLY place instances are turned
# into launchers. `modules/packages.nix` and the `instance-surface` check both
# call this function, so the data-only proof exercises the real packaging path
# rather than a parallel copy of it. Do not branch on the instance name here —
# provider differences belong in `modules/_instances.nix` as data.
{ lib, mkLauncher }:
{
  # instances: attrset from modules/_instances.nix
  # pkgs:       perSystem package set (supplies writeShellApplication, coreutils)
  # claudePackage: the binary to exec; a stub in checks, pkgs.claude-code otherwise
  mkInstanceLaunchers = instances: pkgs: claudePackage:
    lib.mapAttrs
      (_: data: mkLauncher ({ inherit pkgs claudePackage; } // data))
      instances;
}
