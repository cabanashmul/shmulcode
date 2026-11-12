{ inputs, ... }:
{
  # SECURITY: this is the flake's only unfree allowance. The predicate matches
  # exactly one package name — never widen it to a global config.allowUnfree,
  # and do not open-code `import inputs.nixpkgs` in another module: that would
  # bypass this scoped pkgs instance entirely. Downstream modules must consume
  # the `pkgs` module arg, never re-import nixpkgs.
  perSystem = { system, lib, ... }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfreePredicate =
        pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];
    };
  };
}
