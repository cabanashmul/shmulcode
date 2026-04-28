{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";
    jira-mcp.url = "git+ssh://git@github.com/shmul95/jira-mcp";
    jira-mcp.inputs.nixpkgs.follows = "nixpkgs";
    claude-routine.url = "path:/home/shmul95/Repositories/claude-routine";
    claude-routine.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];
      imports = (inputs.import-tree ./modules).imports;
    };
}
