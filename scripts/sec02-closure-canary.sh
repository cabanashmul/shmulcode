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

# CR-03: distinguish grep's three exit statuses. 0 = found (leak), 1 = absent
# (good), anything else = grep could not read the path (scan error). An error
# must NEVER be reported as "no leak".
leak_check() {
  local path="$1" rc=0
  grep -rq -- "$canary" "$path" 2>/dev/null || rc=$?
  case "$rc" in
    0)
      echo "SEC-02 FAIL: canary found in $path" >&2
      exit 1
      ;;
    1)
      return 0  # absent — good
      ;;
    *)
      echo "SEC-02 ERROR: could not scan $path (grep exit $rc)" >&2
      exit 1
      ;;
  esac
}

# CR-03: materialise the closure first so a failed/empty `nix-store -qR` is an
# error rather than a loop that never runs and reports success.
closure="$tmpdir/closure.list"
if ! nix-store -qR "$wrapper" > "$closure"; then
  echo "SEC-02 ERROR: nix-store -qR failed for $wrapper" >&2
  exit 1
fi
closure_count=$(wc -l < "$closure")
if [ "$closure_count" -lt 2 ]; then
  echo "SEC-02 ERROR: suspiciously small closure ($closure_count paths) for $wrapper" >&2
  exit 1
fi

leak_check "$wrapper"
while IFS= read -r p; do
  [ -n "$p" ] && leak_check "$p"
done < "$closure"

echo "SEC-02 ok: canary absent from $wrapper and its $closure_count-path closure"
