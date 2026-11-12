#!/usr/bin/env bash
# SEC-02 host-side proof: no env-file contents enter a wrapper's store closure.
#
# Usage: scripts/sec02-closure-canary.sh [wrapper-store-path]
#
# With no argument, builds a throwaway probe wrapper whose baked envFile is a
# canary file in a temp dir, then scans that wrapper and its full closure for
# the canary value. The canary is generated locally and never touches the repo.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
canary="sk-CANARY-DO-NOT-SHIP-$$"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

envfile="$tmpdir/canary.env"
printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$canary" > "$envfile"
chmod 600 "$envfile"

wrapper="${1:-}"
if [ -z "$wrapper" ]; then
  wrapper="$(nix build --no-link --print-out-paths --impure --expr "
    let
      flake = builtins.getFlake \"$repo\";
      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
      mkLauncher = import $repo/lib/mk-launcher.nix;
      stub = pkgs.writeShellApplication { name = \"claude\"; text = \"exit 0\"; };
    in mkLauncher { inherit pkgs; name = \"canaryprobe\"; envFile = \"$envfile\"; claudePackage = stub; }
  ")"
fi

leak_check() {
  if grep -rqI -- "$canary" "$1" 2>/dev/null; then
    echo "SEC-02 FAIL: canary found in $1" >&2
    exit 1
  fi
}

leak_check "$wrapper"
while IFS= read -r p; do
  leak_check "$p"
done < <(nix-store -qR "$wrapper")

echo "SEC-02 ok: canary absent from $wrapper and its closure"
