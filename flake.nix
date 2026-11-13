{
  description = "shmulcode — provider-multiplexed Claude Code launchers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    # Checks-only: provides `lib.homeManagerConfiguration` for the Phase 5
    # activation check. Never used by packages or the HM module export.
    # `follows` prevents a duplicate nixpkgs in consumers' lock files.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];
      imports = [ (inputs.import-tree ./modules) ];
    };
}
