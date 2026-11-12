{ ... }:
{
  perSystem = { pkgs, lib, config, ... }:
    let
      instances = import ./_instances.nix;
      mkLauncher = import ../lib/mk-launcher.nix;

      # name = "claude" gives $out/bin/claude and meta.mainProgram = "claude",
      # so lib.getExe resolves to the stub exactly as it would to the real package.
      stubClaude = pkgs.writeShellApplication {
        name = "claude";
        text = ''
          echo "STUB-ARGV: $*"
          echo "STUB-BASE: ''${ANTHROPIC_BASE_URL:-unset}"
          echo "STUB-APIKEY: ''${ANTHROPIC_API_KEY+set}"
          echo "STUB-TOKEN: ''${ANTHROPIC_AUTH_TOKEN+set}"
          exit "''${STUB_EXIT:-0}"
        '';
      };

      mk = args: mkLauncher ({ inherit pkgs; claudePackage = stubClaude; } // args);

      # Stub-backed launchers for the real instance data: cheap, offline, and
      # never the real claude-code closure.
      stubLaunchers = lib.mapAttrs (_: data: mk data) instances;

      # A hypothetical fourth provider defined purely as data. It reuses the
      # mimocode entry and overrides only what a new provider would change, so
      # any script difference beyond the name means the builder is not
      # data-driven (INST-04).
      fourthLauncher = mk (instances.mimocode // {
        name = "datacode";
        description = "hypothetical fourth provider (data-only proof)";
      });

      # Mirrors packages.default with stub launchers, so the layout check is
      # cheap and offline while still exercising the exact symlinkJoin shape.
      stubBundle = pkgs.symlinkJoin {
        name = "shmulcode";
        paths = builtins.attrValues stubLaunchers;
      };

      name = "testcode";
      otherName = "othercode";

      validEnv = pkgs.writeText "valid.env" ''
        ANTHROPIC_BASE_URL=https://example.test
        ANTHROPIC_AUTH_TOKEN=tok-abc
      '';

      defaultWrapper = mk { inherit name; };
      otherWrapper = mk { name = otherName; };
      bakedMissing = mk { inherit name; envFile = "/nonexistent/definitely-missing.env"; };
      fixedArgs = mk { inherit name; extraArgs = [ "--fixed" ]; };
      runtimePath = mk { inherit name; envFile = "\${XDG_RUNTIME_DIR}/agenix/testcode.env"; };
      # Baked path whose parent root is supplied at run time, so the check can
      # create the target with mode 000 and prove the "unreadable" branch.
      bakedUnreadable = mk { inherit name; envFile = "\${UNREADABLE_ROOT}/unreadable.env"; };
    in
    {
      checks = {
        # Keep the unfree proof but make it eval-only so `nix flake check`
        # never downloads the real 100MB+ binary.
        claude-code-unfree-eval =
          builtins.seq pkgs.claude-code.drvPath (pkgs.writeText "claude-code-eval-ok" "ok");

        # DIST-01/DIST-02 + INST-01..03: assert the real package/app surface at
        # evaluation time only. builtins.seq forces instantiation (a broken
        # attribute fails) but never builds, so claude-code stays out of this
        # check's build closure.
        packages-surface =
          let
            names = builtins.attrNames instances;          # already sorted
            expectedPackages = builtins.sort builtins.lessThan (names ++ [ "default" ]);
          in
          builtins.seq config.packages.default.drvPath (
            assert builtins.all (n: builtins.elem n names) [ "mimocode" "deepcode" "grokcode" ];
            assert builtins.attrNames config.packages == expectedPackages;
            assert builtins.attrNames config.apps == names;
            assert builtins.all (n: config.packages.${n}.meta.mainProgram == n) names;
            assert config.packages.default.name == "shmulcode";
            assert map (d: d.name) config.packages.default.launchers == names;
            assert !(builtins.elem "claude" (map (d: d.name) config.packages.default.launchers));
            assert builtins.all (n: config.apps.${n}.type == "app") names;
            assert builtins.all (n: config.apps.${n}.program == lib.getExe config.packages.${n}) names;
            pkgs.writeText "packages-surface-ok" "ok"
          );

        # INST-01..03: each built-in instance renders a real launcher through
        # the same builder and carries the shared required-var contract.
        # INST-04: a fourth data-only instance is identical to mimocode after
        # name normalisation, with controls so the assertion cannot be vacuous.
        instance-surface = pkgs.runCommand "instance-surface" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.diffutils ];
        } ''
          set -euo pipefail
          OUT=$out
          fail() { echo "FAIL: $*" >&2; exit 1; }
          work="$TMPDIR/inst"; mkdir -p "$work"

          ${lib.concatMapStrings (n: ''
            W=${stubLaunchers.${n}}/bin/${n}
            test -x "$W" || fail "INST ${n}: launcher not executable"
            grep -Eq 'exec /nix/store/[^ "]+/bin/claude' "$W" || fail "INST ${n}: exec is not an absolute store path"
            grep -q 'command -v' "$W" && fail "INST ${n}: PATH lookup present"
            grep -q 'ANTHROPIC_BASE_URL' "$W" || fail "INST ${n}: ANTHROPIC_BASE_URL requirement missing"
            grep -q 'ANTHROPIC_AUTH_TOKEN' "$W" || fail "INST ${n}: ANTHROPIC_AUTH_TOKEN requirement missing"
            grep -q 'ANTHROPIC_API_KEY' "$W" || fail "INST ${n}: ANTHROPIC_API_KEY requirement missing"
            grep -q '/${n}/env' "$W" || fail "INST ${n}: default env path missing"
          '') (builtins.attrNames instances)}

          A=${stubLaunchers.mimocode}/bin/mimocode
          # Resolve the fourth launcher's bin from its own meta.mainProgram
          # rather than hardcoding datacode, so control 0 below stays reachable
          # even if the fourth instance is temporarily renamed.
          B=${lib.getExe fourthLauncher}

          # control 0: the renderings must genuinely differ before
          # normalisation, otherwise the final cmp is vacuous.
          cmp -s "$A" "$B" && fail "INST-04 vacuous: scripts identical before normalisation"

          sed -e 's/mimocode/@NAME@/g' "$A" > "$work/a"
          sed -e 's/datacode/@NAME@/g' "$B" > "$work/b"

          # control 1: normalisation actually applied to both files.
          grep -q '@NAME@' "$work/a" || fail "INST-04 normalisation not applied to mimocode"
          grep -q '@NAME@' "$work/b" || fail "INST-04 normalisation not applied to fourth"

          # control 2: the normalised file is still a real launcher.
          grep -Eq 'exec /nix/store/' "$work/a" || fail "INST-04 normalised script lost its exec line"

          # the invariant: data-only means identical after replacing the name.
          cmp -s "$work/a" "$work/b" || { diff -u "$work/a" "$work/b" >&2 || true; fail "INST-04 scripts differ beyond interpolated values"; }

          touch "$OUT"
        '';

        # DIST-03: the default-bundle layout is exactly one bin per instance and
        # never claude. Uses stubBundle, never config.packages.default, so this
        # check does not pull claude-code into its build closure.
        bundle-layout = pkgs.runCommand "bundle-layout" {
          nativeBuildInputs = [ pkgs.coreutils ];
        } ''
          set -euo pipefail
          OUT=$out
          B=${stubBundle}
          names="${lib.concatStringsSep " " (builtins.attrNames instances)}"
          for n in $names; do
            test -e "$B/bin/$n" || { echo "FAIL: bundle missing bin/$n" >&2; exit 1; }
          done
          count=$(ls "$B/bin" | wc -l)
          [ "$count" -eq ${toString (builtins.length (builtins.attrNames instances))} ] \
            || { echo "FAIL: bundle bin count $count" >&2; exit 1; }
          [ ! -e "$B/bin/claude" ] || { echo "FAIL: bundle ships claude" >&2; exit 1; }
          touch "$OUT"
        '';

        launcher-contract = pkgs.runCommand "launcher-contract" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
        } ''
          set -euo pipefail
          OUT=$out   # capture BEFORE any test reuses `out`
          fail() { echo "FAIL: $*" >&2; exit 1; }
          pass() { echo "ok - $*"; }

          W=${defaultWrapper}/bin/testcode
          O=${otherWrapper}/bin/othercode
          BW=${bakedMissing}/bin/testcode
          FW=${fixedArgs}/bin/testcode
          RW=${runtimePath}/bin/testcode
          UW=${bakedUnreadable}/bin/testcode

          work="$TMPDIR/work"
          mkdir -p "$work/xdg/testcode" "$work/home" "$work/rt/agenix"
          cp ${validEnv} "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          export XDG_CONFIG_HOME="$work/xdg" HOME="$work/home"

          # CORE-04: writeShellApplication strict mode (shellcheck ran at build)
          grep -q 'set -o errexit' "$W" || fail "CORE-04 errexit"
          grep -q 'set -o nounset' "$W" || fail "CORE-04 nounset"
          grep -q 'set -o pipefail' "$W" || fail "CORE-04 pipefail"
          pass "CORE-04 strict mode + shellcheck"

          # CORE-02: absolute store path, never a PATH lookup
          grep -Eq 'exec /nix/store/[^ "]+/bin/claude' "$W" || fail "CORE-02 absolute exec"
          grep -q 'command -v' "$W" && fail "CORE-02 PATH lookup present"
          pass "CORE-02 absolute exec"

          # CORE-01: one builder; two instances differ only in interpolated data
          sed -e 's/testcode/NAME/g' -e 's/othercode/NAME/g' "$W" > "$work/a.sh"
          sed -e 's/testcode/NAME/g' -e 's/othercode/NAME/g' "$O" > "$work/b.sh"
          cmp -s "$work/a.sh" "$work/b.sh" || fail "CORE-01 scripts differ beyond data"
          pass "CORE-01 single builder, data-only"

          # CORE-03 + ENV-04: source into process, argv and exit code pass through
          set +e; got=$(STUB_EXIT=42 "$W" --foo bar 2>"$work/err"); rc=$?; set -e
          echo "$got" | grep -q 'STUB-ARGV: --foo bar' || fail "CORE-03 argv"
          echo "$got" | grep -q 'STUB-BASE: https://example.test' || fail "ENV-04 source"
          [ "$rc" -eq 42 ] || fail "CORE-03 exit code ($rc)"
          pass "CORE-03/ENV-04 argv+exit+source"

          # extraArgs precede user args
          set +e; got=$(STUB_EXIT=0 "$FW" --user 2>/dev/null); set -e
          echo "$got" | grep -q 'STUB-ARGV: --fixed --user' || fail "extraArgs order"
          pass "extraArgs ordering"

          # ENV-01: SHMULCODE_ENV_FILE override wins over a baked path
          ALT="$work/alt.env"; cp ${validEnv} "$ALT"; chmod 600 "$ALT"
          set +e; got=$(SHMULCODE_ENV_FILE="$ALT" STUB_EXIT=0 "$BW" 2>/dev/null); set -e
          echo "$got" | grep -q 'STUB-ARGV' || fail "ENV-01 override precedence"
          pass "ENV-01 override precedence"

          # ENV-01: baked ''${XDG_RUNTIME_DIR} expands at runtime
          cp ${validEnv} "$work/rt/agenix/testcode.env"
          chmod 600 "$work/rt/agenix/testcode.env"
          set +e; got=$(XDG_RUNTIME_DIR="$work/rt" STUB_EXIT=0 "$RW" --v 2>"$work/e2"); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "ENV-01 runtime path ($rc): $(cat "$work/e2")"
          echo "$got" | grep -q 'STUB-ARGV: --v' || fail "ENV-01 XDG_RUNTIME_DIR expansion"
          pass "ENV-01 runtime expansion"

          # ENV-02/ENV-03/ENV-07: default missing file -> 78, names path/name/vars/init
          rm -f "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "ENV-07 missing file ($rc)"
          echo "$err" | grep -q 'testcode' || fail "ENV-03 instance name"
          echo "$err" | grep -q "$work/xdg/testcode/env" || fail "ENV-03 resolved path"
          echo "$err" | grep -q 'ANTHROPIC_BASE_URL' || fail "ENV-03 variable names"
          echo "$err" | grep -q 'shmulcode init' || fail "ENV-03 init hint"
          pass "ENV-02/03/07 missing file"

          # ENV-02: baked missing never falls back to a valid XDG file
          cp ${validEnv} "$work/xdg/testcode/env"; chmod 600 "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$BW" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "ENV-02 baked missing ($rc)"
          echo "$err" | grep -q '/nonexistent/definitely-missing.env' || fail "ENV-02 baked path named"
          echo "$err" | grep -q 'STUB-ARGV' && fail "ENV-02 fell back to XDG"
          pass "ENV-02 no fallback"

          # ENV-02/ENV-07: baked path present but UNREADABLE -> 78, no fallback.
          # Runs as the unprivileged nixbld user in the sandbox, so 000 is
          # genuinely unreadable here (would be bypassed as root — do not
          # convert this check to run as root).
          cp ${validEnv} "$work/xdg/testcode/env"; chmod 600 "$work/xdg/testcode/env"
          UNREADABLE="$work/unreadable.env"; cp ${validEnv} "$UNREADABLE"; chmod 000 "$UNREADABLE"
          set +e; err=$(UNREADABLE_ROOT="$work" "$UW" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "ENV-02 baked unreadable ($rc)"
          echo "$err" | grep -q "$UNREADABLE" || fail "ENV-02 unreadable path named"
          echo "$err" | grep -q 'STUB-ARGV' && fail "ENV-02 unreadable fell back to XDG"
          pass "ENV-02 unreadable no fallback"

          # ENV-02/ENV-07 (Pitfall 9): neither XDG_CONFIG_HOME nor HOME set
          # -> cannot resolve a fallback path -> 78 naming the instance.
          set +e; err=$(env -i STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "ENV-07 no HOME/XDG ($rc)"
          echo "$err" | grep -q 'testcode' || fail "ENV-07 no HOME/XDG names instance"
          pass "ENV-07 no HOME/XDG"

          # ENV-05: base URL + exactly one credential; both set warns but passes through
          printf 'ANTHROPIC_AUTH_TOKEN=tok\n' > "$work/xdg/testcode/env"; chmod 600 "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "ENV-05 missing base ($rc)"
          echo "$err" | grep -q 'ANTHROPIC_BASE_URL' || fail "ENV-05 missing base named"
          printf 'ANTHROPIC_BASE_URL=https://example.test\n' > "$work/xdg/testcode/env"; chmod 600 "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "ENV-05 no credential ($rc)"
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=a\nANTHROPIC_API_KEY=k\n' > "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=7 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 7 ] || fail "ENV-05 both-set blocked ($rc)"
          echo "$err" | grep -q 'auth may not work as expected' || fail "ENV-05 both-set warning"
          pass "ENV-05 credential validation"

          # CORE-05: ambient ANTHROPIC_* dropped before sourcing
          cp ${validEnv} "$work/xdg/testcode/env"; chmod 600 "$work/xdg/testcode/env"
          set +e; got=$(ANTHROPIC_API_KEY=ambient-leak STUB_EXIT=0 "$W" 2>/dev/null); set -e
          echo "$got" | grep -q 'STUB-APIKEY: set' && fail "CORE-05 ambient key survived"
          echo "$got" | grep -q 'STUB-TOKEN: set' || fail "CORE-05 file token missing"
          pass "CORE-05 env hygiene"

          # ENV-06: bitmask warning; 644 warns, 600 is quiet, symlink to 600 is quiet
          chmod 644 "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); set -e
          echo "$err" | grep -q 'group/world-accessible' || fail "ENV-06 644 not flagged"
          chmod 600 "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); set -e
          echo "$err" | grep -q 'group/world-accessible' && fail "ENV-06 600 flagged"
          ln -sf "$work/xdg/testcode/env" "$work/link.env"
          set +e; err=$(SHMULCODE_ENV_FILE="$work/link.env" STUB_EXIT=0 "$W" 2>&1); set -e
          echo "$err" | grep -q 'group/world-accessible' && fail "ENV-06 symlink followed wrong"
          pass "ENV-06 permission bitmask"

          # ENV-04: CRLF, BOM, syntax each -> 78 with the matching message
          printf 'ANTHROPIC_BASE_URL=x\r\nANTHROPIC_AUTH_TOKEN=y\r\n' > "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] && echo "$err" | grep -q 'CRLF' || fail "ENV-04 CRLF ($rc)"
          printf '\xef\xbb\xbfANTHROPIC_BASE_URL=x\n' > "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] && echo "$err" | grep -q 'BOM' || fail "ENV-04 BOM ($rc)"
          printf 'ANTHROPIC_BASE_URL=(\n' > "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] && echo "$err" | grep -q 'syntax errors' || fail "ENV-04 syntax ($rc)"
          pass "ENV-04 preflight"

          # ENV-07: an unset reference inside the env file must still yield 78
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=$UNSET_VAR_XYZ\n' > "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          set +e; err=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "ENV-07 unset-in-file exited $rc (want 78)"
          pass "ENV-07 set +u scoping"

          # SEC-02: PATH-stripped invocation still execs the absolute store path
          cp ${validEnv} "$work/xdg/testcode/env"; chmod 600 "$work/xdg/testcode/env"
          set +e; got=$(env -i XDG_CONFIG_HOME="$work/xdg" STUB_EXIT=0 "$W" 2>"$work/e3"); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "SEC-02 PATH-stripped ($rc): $(cat "$work/e3")"
          echo "$got" | grep -q 'STUB-ARGV' || fail "SEC-02 stub did not run"
          pass "SEC-02 PATH-stripped"

          # SEC-03: credential values never appear in diagnostics.
          CANARY='sk-CANARY-DO-NOT-PRINT'
          # Positive control: the detector must actually detect. Without this,
          # every "canary absent" assertion below could pass vacuously if the
          # stub stopped echoing (e.g. a typo in the variable name).
          printf 'STUB-ARGV: %s\n' "$CANARY" > "$work/control.txt"
          grep -q "$CANARY" "$work/control.txt" || fail "SEC-03 positive control (detector broken)"

          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          set +e; diag=$(STUB_EXIT=0 "$W" 2>&1); set -e
          echo "$diag" | grep -q "$CANARY" && fail "SEC-03 canary leaked on success"
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_API_KEY=%s\n' "$CANARY" > "$work/xdg/testcode/env"
          chmod 644 "$work/xdg/testcode/env"
          set +e; diag=$(STUB_EXIT=0 "$W" 2>&1); set -e
          echo "$diag" | grep -q "$CANARY" && fail "SEC-03 canary leaked in warnings"
          # CR-01 regression: a syntax error on a credential-bearing line must
          # not make bash -n echo that line (which would print the canary).
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_API_KEY=%s(\n' "$CANARY" > "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          set +e; diag=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "SEC-03/ENV-04 syntax error rc ($rc, want 78)"
          echo "$diag" | grep -q "$CANARY" && fail "SEC-03 CR-01 canary leaked via bash -n"
          pass "SEC-03 no values in diagnostics"

          touch "$OUT"
        '';

        # SEC-01: no eval-time secret access anywhere in the flake's Nix source.
        # modules/checks.nix is excluded on purpose: it holds this pattern
        # literal and would match its own source.
        #
        # The regex covers the readFile family and its nixpkgs lib aliases
        # (lib.fileContents, lib.importJSON/importTOML) plus types.path, which
        # would copy a secret into the store. Bare path literals that look like
        # secret files (./secrets/env) are flagged too — pass a string instead.
        sec01-no-eval-secret-reads = pkgs.runCommand "sec01-no-eval-secret-reads" {
          nativeBuildInputs = [ pkgs.gnugrep ];
        } ''
          set -euo pipefail
          pattern='readFile|fileContents|importJSON|importTOML|types\.path|builtins\.path|\./[A-Za-z._/-]*(secret|secrets|\.env)'
          # Self-test: the regex must catch every shape when one exists.
          for bad in \
            'builtins.readFile ./s' \
            'lib.fileContents ./s' \
            'lib.importJSON ./s' \
            'types.path' \
            'envFile = ./secrets/env;'
          do
            printf '%s\n' "$bad" > "$TMPDIR/bad.nix"
            grep -qE "$pattern" "$TMPDIR/bad.nix" \
              || { echo "SEC-01 FAIL: lint regex misses: $bad" >&2; exit 1; }
          done
          if grep -rnE "$pattern" ${../lib} ${./pkgs.nix} ${./packages.nix} ${./_instances.nix} ${../flake.nix}; then
            echo "SEC-01 FAIL: eval-time secret access found above" >&2
            exit 1
          fi
          touch "$out"
        '';
      };
    };
}
