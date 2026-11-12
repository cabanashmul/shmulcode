{ ... }:
{
  perSystem = { pkgs, ... }: {
    # Proves the scoped allowUnfreePredicate in modules/pkgs.nix actually
    # reaches claude-code. Deliberately a `checks` entry, not a
    # dedicated package output — a real one is Phase 2/3's job
    # once the wrapper exists and needs it.
    checks.claude-code-unfree-eval = pkgs.claude-code;
  };
}
