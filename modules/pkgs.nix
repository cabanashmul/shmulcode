{ inputs, ... }:
{
  perSystem = { system, lib, ... }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfreePredicate =
        pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];
    };
  };
}
