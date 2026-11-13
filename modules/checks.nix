{ inputs, config, ... }:
{
  # Per-system module args are bound as `ps` so the top-level `config`
  # (flake-parts' flake config, which owns `systems`) is not shadowed and stays
  # in scope for the Home Manager fixtures below.
  perSystem = { pkgs, lib, ... }@ps:
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

      # CR-02: use the SAME mapping modules/packages.nix uses, so the data-only
      # proof exercises the real packaging path — a per-provider branch added to
      # that mapping is caught here, whereas a private mkLauncher copy would
      # not catch it.
      inherit (import ../lib/mk-instance-launchers.nix { inherit lib mkLauncher; })
        mkInstanceLaunchers;

      # Stub-backed launchers for the real instance data: cheap, offline, and
      # never the real claude-code closure.
      stubLaunchers = mkInstanceLaunchers instances pkgs stubClaude;

      # A hypothetical fourth provider defined purely as data, routed through
      # the shared mapping. It reuses the mimocode entry and overrides only what
      # a new provider would change, so any script difference beyond the name
      # means the instance→launcher path is not data-driven (INST-04).
      fourthLauncher =
        (mkInstanceLaunchers
          { datacode = instances.mimocode // { name = "datacode"; description = "hypothetical fourth provider (data-only proof)"; }; }
          pkgs
          stubClaude).datacode;

      # Mirrors packages.default with stub launchers, so the layout check is
      # cheap and offline while still exercising the exact symlinkJoin shape.
      # shmulcode is the real admin package: its script has no claude exec, so
      # it adds nothing to the build closure.
      stubBundle = pkgs.symlinkJoin {
        name = "shmulcode";
        paths = builtins.attrValues stubLaunchers ++ [ ps.config.packages.shmulcode ];
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

      # ---- Phase 5: Home Manager module -----------------------------------
      hmModule = import ../lib/hm-module.nix {
        inherit (inputs) nixpkgs;
        supportedSystems = config.systems;  # derived from flake.nix; do not hardcode
      };

      # A stub named `claude` keeps the real unfree closure out of nix flake check.
      hmStub = pkgs.writeShellApplication {
        name = "claude";
        text = ''
          echo "STUB-ARGV: $*"
          exit 0
        '';
      };

      hmBase = {
        home.username = "shmulcode-hm-test";
        home.homeDirectory = "/home/shmulcode-hm-test";
        home.stateVersion = "26.11";
        programs.man.enable = false;      # drop man-db
        xdg.mime.enable = false;          # drop shared-mime-info
        manual.manpages.enable = false;   # drop the reference manpage
      };

      mkHome = extraModules: inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ hmBase hmModule ] ++ extraModules;
      };

      # Success canary: one baked instance plus one renamed, runtime-resolution
      # instance (the latter exercises envName in the XDG/HOME path and the hint).
      hmGood = mkHome [{
        programs.shmulcode.instances = {
          mimocode = {
            enable = true;
            envFile = "/run/agenix/mimocode-env";
            package = hmStub;
          };
          grokcode = {
            enable = true;
            command = "grok";
            envFile = null;
            package = hmStub;
          };
        };
      }];

      # No user instance definitions: the attrs default gives three disabled
      # built-ins, so no launcher may appear.
      hmZero = mkHome [ { } ];

      # Defining only envFile must NOT enable the instance (explicit enable).
      hmDisabledOnly = mkHome [{
        programs.shmulcode.instances.deepcode.envFile = "/run/agenix/deepcode-env";
      }];

      # Failure probes, one per assertion.
      hmStore = mkHome [{
        programs.shmulcode.instances.mimocode = {
          enable = true;
          envFile = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-env";
          package = hmStub;
        };
      }];

      hmEmpty = mkHome [{
        programs.shmulcode.instances.mimocode = {
          enable = true;
          envFile = "";
          package = hmStub;
        };
      }];

      hmBadCommand = mkHome [{
        programs.shmulcode.instances.mimocode = {
          enable = true;
          command = "mimo; touch /tmp/pwned";
          envFile = "/run/agenix/mimocode-env";
          package = hmStub;
        };
      }];

      hmBadVars = mkHome [{
        programs.shmulcode.instances.mimocode = {
          enable = true;
          envFile = "/run/agenix/mimocode-env";
          requiredVars = [ "ANTHROPIC_BASE_URL; touch /tmp/pwned" ];
          package = hmStub;
        };
      }];

      hmBadPath = mkHome [{
        programs.shmulcode.instances.mimocode = {
          enable = true;
          envFile = "/run/agenix/mimo code\"$(touch /tmp/pwned)";
          package = hmStub;
        };
      }];

      hmDup = mkHome [{
        programs.shmulcode.instances = {
          mimocode = { enable = true; command = "same"; envFile = "/run/agenix/a"; package = hmStub; };
          deepcode = { enable = true; command = "same"; envFile = "/run/agenix/b"; package = hmStub; };
        };
      }];

      hmReserved = mkHome [{
        programs.shmulcode.instances.mimocode = {
          enable = true;
          command = "claude";
          envFile = "/run/agenix/a";
          package = hmStub;
        };
      }];

      # Mechanism-agnostic canary: a fake agenix-shaped option, no agenix import.
      hmAgenix = mkHome [
        ({ lib, ... }: {
          options.age.secrets = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options.path = lib.mkOption { type = lib.types.str; };
            });
            default = { };
          };
        })
        ({ config, ... }: {
          config.age.secrets."mimocode-env".path = "/run/agenix/mimocode-env";
          config.programs.shmulcode.instances.mimocode = {
            enable = true;
            envFile = config.age.secrets."mimocode-env".path;
            package = hmStub;
          };
        })
      ];

      # tryEval catches HM's assertion throw; use drvPath to force config + assertions.
      hmTry = x: (builtins.tryEval (builtins.deepSeq x x)).success;
      hmPackageNames = h: map (p: p.name) h.config.home.packages;

      hmResults = {
        goodActivates = hmTry hmGood.activationPackage.drvPath;
        goodPackages = hmPackageNames hmGood;
        zeroHasNoLaunchers = !(builtins.any
          (n: builtins.elem n (hmPackageNames hmZero))
          [ "mimocode" "deepcode" "grokcode" "grok" ]);
        # HMOD-07 (the "built-ins are available" half): a config that enables
        # nothing must still SEE the three built-in instances as declared
        # options. Without this, an empty `instances` default would pass
        # zeroHasNoLaunchers vacuously.
        builtinsAreDeclared =
          builtins.attrNames hmZero.config.programs.shmulcode.instances
            == [ "deepcode" "grokcode" "mimocode" ];
        disabledOnlyHasNoLaunchers = !(builtins.elem "deepcode" (hmPackageNames hmDisabledOnly));
        storeFails = !(hmTry hmStore.activationPackage.drvPath);
        emptyFails = !(hmTry hmEmpty.activationPackage.drvPath);
        badCommandFails = !(hmTry hmBadCommand.activationPackage.drvPath);
        badVarsFails = !(hmTry hmBadVars.activationPackage.drvPath);
        badPathFails = !(hmTry hmBadPath.activationPackage.drvPath);
        duplicateCommandsFail = !(hmTry hmDup.activationPackage.drvPath);
        reservedCommandFails = !(hmTry hmReserved.activationPackage.drvPath);
        agenixRefEvaluates = hmTry hmAgenix.activationPackage.drvPath;
      };
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
            expectedPackages = builtins.sort builtins.lessThan (names ++ [ "default" "shmulcode" ]);
          in
          builtins.seq ps.config.packages.default.drvPath (
            assert builtins.all (n: builtins.elem n names) [ "mimocode" "deepcode" "grokcode" ];
            assert builtins.attrNames ps.config.packages == expectedPackages;
            assert builtins.attrNames ps.config.apps == names;
            assert builtins.all (n: ps.config.packages.${n}.meta.mainProgram == n) names;
            assert ps.config.packages.shmulcode.meta.mainProgram == "shmulcode";
            assert ps.config.packages.default.name == "shmulcode";
            # passthru.launchers keeps its Phase 3 meaning: launchers only.
            assert map (d: d.name) ps.config.packages.default.launchers == names;
            assert !(builtins.elem "claude" (map (d: d.name) ps.config.packages.default.launchers));
            # ADMIN: the bundle joins the launchers AND the admin command.
            assert ps.config.packages.default.admin == ps.config.packages.shmulcode;
            # WR-01 (extended): compare by store path so a regression to a
            # launcher-only bundle fails here even if passthru stays correct.
            assert map toString ps.config.packages.default.paths
              == map toString (ps.config.packages.default.launchers ++ [ ps.config.packages.default.admin ]);
            assert builtins.length ps.config.packages.default.paths == builtins.length names + 1;
            assert builtins.all (n: ps.config.apps.${n}.type == "app") names;
            assert builtins.all (n: ps.config.apps.${n}.program == lib.getExe ps.config.packages.${n}) names;
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
            grep -q '/${n}/env' "$W" || fail "INST ${n}: default env path missing"
          ''
          # WR-02: assert the required vars this instance actually declares,
          # not a hardcoded pair — otherwise a data-only provider with a
          # different requiredVars shape would fail the check, contradicting
          # "adding an instance is data only".
          + lib.concatMapStrings
            (g: lib.concatMapStrings (v: ''
              grep -q '${v}' "$W" || fail "INST ${n}: ${v} requirement missing"
            '') (if builtins.isList g then g else [ g ]))
            (instances.${n}.requiredVars
              or [ "ANTHROPIC_BASE_URL" [ "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_API_KEY" ] ])
          ) (builtins.attrNames instances)}

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

        # DIST-03 + ADMIN-03 bundling: the default bundle is exactly one bin per
        # instance plus `shmulcode`, and never `claude`. Uses stubBundle, never
        # ps.config.packages.default, so this check does not pull claude-code in.
        bundle-layout = pkgs.runCommand "bundle-layout" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
        } ''
          set -euo pipefail
          OUT=$out
          fail() { echo "FAIL: $*" >&2; exit 1; }
          B=${stubBundle}
          names="${lib.concatStringsSep " " (builtins.attrNames instances)}"
          for n in $names; do
            test -e "$B/bin/$n" || fail "bundle missing bin/$n"
          done
          test -x "$B/bin/shmulcode" || fail "bundle missing executable bin/shmulcode"
          count=$(ls "$B/bin" | wc -l)
          [ "$count" -eq ${toString (builtins.length (builtins.attrNames instances) + 1)} ] \
            || fail "bundle bin count $count (want ${toString (builtins.length (builtins.attrNames instances) + 1)})"
          [ ! -e "$B/bin/claude" ] || fail "bundle ships claude"
          # The admin command is diagnostics only: it must never launch claude.
          if grep -qE 'exec /nix/store/[^ "]+/bin/claude' "$B/bin/shmulcode"; then
            fail "admin command execs claude"
          fi
          touch "$OUT"
        '';

        # ADMIN-01: init writes a 0600 values-free template, refuses to
        # clobber, honours SHMULCODE_ENV_FILE, and rejects bad names with 64.
        admin-init = pkgs.runCommand "admin-init" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
        } ''
          set -euo pipefail
          OUT=$out
          fail() { echo "FAIL: $*" >&2; exit 1; }
          work="$TMPDIR/admin-init"; mkdir -p "$work/xdg"
          export XDG_CONFIG_HOME="$work/xdg" HOME="$work"
          S=${ps.config.packages.shmulcode}/bin/shmulcode

          set +e; out=$("$S" 2>&1); rc=$?; set -e
          [ "$rc" -eq 64 ] || fail "no-arg rc $rc (want 64)"
          echo "$out" | grep -q 'usage: shmulcode' || fail "usage text missing"
          set +e; out=$("$S" nosuchverb 2>&1); rc=$?; set -e
          [ "$rc" -eq 64 ] || fail "unknown verb rc $rc (want 64)"
          set +e; out=$("$S" init ../evil 2>&1); rc=$?; set -e
          [ "$rc" -eq 64 ] || fail "traversal name rc $rc (want 64)"
          [ ! -e "$work/evil" ] || fail "traversal created a file"
          # An unknown-but-safe instance name is also a usage error and must
          # create nothing (the allowlist also covers `a/b` and `-rf`).
          set +e; out=$("$S" init nosuchinstance 2>&1); rc=$?; set -e
          [ "$rc" -eq 64 ] || fail "unknown instance rc $rc (want 64)"
          [ ! -e "$work/xdg/nosuchinstance" ] || fail "unknown instance created a file"

          "$S" init mimocode >/dev/null
          f="$work/xdg/mimocode/env"
          [ -f "$f" ] || fail "init did not create $f"
          [ "$(stat -c '%a' "$f")" = "600" ] || fail "init mode $(stat -c '%a' "$f") (want 600)"
          for v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY; do
            grep -q "$v" "$f" || fail "template omits $v"
          done
          # No uncommented line may exist: a template never carries a value.
          if grep -vE '^[[:space:]]*(#|$)' "$f" | grep -q .; then
            fail "template contains an uncommented line"
          fi
          # Positive control: the detector above does catch an export line.
          printf 'export ANTHROPIC_BASE_URL=x\n' > "$work/control"
          grep -vE '^[[:space:]]*(#|$)' "$work/control" | grep -q . \
            || fail "uncommented-line detector broken"

          cp "$f" "$work/before"
          set +e; out=$("$S" init mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 73 ] || fail "clobber rc $rc (want 73)"
          echo "$out" | grep -q 'refusing to overwrite' || fail "clobber message missing"
          cmp -s "$f" "$work/before" || fail "init modified an existing file"

          alt="$work/alt.env"
          SHMULCODE_ENV_FILE="$alt" "$S" init mimocode >/dev/null
          [ -f "$alt" ] || fail "SHMULCODE_ENV_FILE override not honoured"
          [ "$(stat -c '%a' "$alt")" = "600" ] || fail "override mode not 600"
          touch "$OUT"
        '';

        # ADMIN-02/03: doctor reports rule, path, stat fields and presence-only
        # variables with a 0/78 exit; list covers every instance; neither ever
        # prints a credential value (SEC-03 canary with a positive control).
        admin-doctor-list = pkgs.runCommand "admin-doctor-list" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.diffutils ];
        } ''
          set -euo pipefail
          OUT=$out
          fail() { echo "FAIL: $*" >&2; exit 1; }
          work="$TMPDIR/admin-doc"; mkdir -p "$work/xdg/mimocode"
          export XDG_CONFIG_HOME="$work/xdg" HOME="$work"
          S=${ps.config.packages.shmulcode}/bin/shmulcode
          CANARY='sk-CANARY-DO-NOT-PRINT'
          printf 'x %s\n' "$CANARY" > "$work/control.txt"
          grep -q "$CANARY" "$work/control.txt" || fail "canary detector broken"

          set +e; out=$("$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "doctor missing rc $rc (want 78)"
          echo "$out" | grep -q "$work/xdg/mimocode/env" || fail "doctor: path not printed"
          echo "$out" | grep -q 'default path (XDG_CONFIG_HOME)' || fail "doctor: rule not printed"
          echo "$out" | grep -q 'shmulcode init' || fail "doctor: init hint absent"

          # No HOME and no XDG_CONFIG_HOME: doctor must fail closed with 78
          # (same contract as the launcher), not guess a path.
          set +e; out=$(env -i "$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "doctor no HOME/XDG rc $rc (want 78)"

          # CRLF is rejected by doctor exactly like the launcher (78), never
          # reported as usable.
          printf 'ANTHROPIC_BASE_URL=https://example.test\r\nANTHROPIC_AUTH_TOKEN=x\r\n' > "$work/xdg/mimocode/env"
          chmod 600 "$work/xdg/mimocode/env"
          set +e; out=$("$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "doctor CRLF rc $rc (want 78)"
          echo "$out" | grep -q 'CRLF' || fail "doctor: CRLF not named"

          # CR-01: a syntax error on a credential line must not make doctor
          # echo the line (bash -n diagnostic) — 78 with no canary.
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_API_KEY=%s(\n' "$CANARY" > "$work/xdg/mimocode/env"
          chmod 600 "$work/xdg/mimocode/env"
          set +e; out=$("$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "doctor syntax rc $rc (want 78)"
          echo "$out" | grep -q "$CANARY" && fail "doctor leaked canary via syntax error"

          # CR-02: ambient xtrace must not leak values from doctor either.
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/mimocode/env"
          chmod 600 "$work/xdg/mimocode/env"
          set +e; out=$(env SHELLOPTS=xtrace "$S" doctor mimocode 2>&1); rc=$?; set -e
          echo "$out" | grep -q "$CANARY" && fail "doctor leaked canary via ambient xtrace"

          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/mimocode/env"
          chmod 600 "$work/xdg/mimocode/env"
          set +e; out=$("$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "doctor usable rc $rc"
          echo "$out" | grep -q 'mode: 600' || fail "doctor: mode not shown"
          echo "$out" | grep -q 'ANTHROPIC_BASE_URL: set' || fail "doctor: base presence missing"
          echo "$out" | grep -q 'ANTHROPIC_AUTH_TOKEN/ANTHROPIC_API_KEY: set' || fail "doctor: credential presence missing"
          echo "$out" | grep -q 'claude doctor' || fail "doctor: claude doctor hint missing"
          if echo "$out" | grep -q "$CANARY"; then fail "doctor leaked canary"; fi

          printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/mimocode/env"
          chmod 600 "$work/xdg/mimocode/env"
          set +e; out=$("$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "doctor partial rc $rc (want 78)"
          echo "$out" | grep -q 'missing required variables: ANTHROPIC_BASE_URL' || fail "doctor: missing var not named"
          if echo "$out" | grep -q "$CANARY"; then fail "doctor partial leaked canary"; fi

          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/mimocode/env"
          chmod 644 "$work/xdg/mimocode/env"
          set +e; out=$("$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "doctor 644 rc $rc (warning must be non-blocking)"
          echo "$out" | grep -q 'group/world-accessible' || fail "doctor: 644 not flagged"
          if echo "$out" | grep -q "$CANARY"; then fail "doctor 644 leaked canary"; fi
          chmod 600 "$work/xdg/mimocode/env"

          "$S" doctor mimocode > "$work/d.txt" 2>&1 || fail "doctor failed for diff"
          "$S" info mimocode > "$work/i.txt" 2>&1 || fail "info failed for diff"
          diff -u "$work/d.txt" "$work/i.txt" || fail "info output differs from doctor"

          alt="$work/alt.env"; cp "$work/xdg/mimocode/env" "$alt"; chmod 600 "$alt"
          set +e; out=$(SHMULCODE_ENV_FILE="$alt" "$S" doctor mimocode 2>&1); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "doctor override rc $rc"
          echo "$out" | grep -q 'SHMULCODE_ENV_FILE override' || fail "doctor: override rule not shown"

          set +e; out=$("$S" list 2>&1); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "list rc $rc"
          for n in ${lib.concatStringsSep " " (builtins.attrNames instances)}; do
            cnt=$(echo "$out" | grep -c "^$n — " || true)
            [ "$cnt" -eq 1 ] || fail "list: $n appears $cnt times (want exactly 1)"
          done
          echo "$out" | grep -q '(present' || fail "list: no present state"
          echo "$out" | grep -q '(missing' || fail "list: no missing state"
          if echo "$out" | grep -q "$CANARY"; then fail "list leaked canary"; fi
          touch "$OUT"
        '';

        # ADMIN-03: SHMULCODE_DEBUG=1 makes the launcher print rule/path/mode
        # to stderr before sourcing, and never a value. Unset means silence.
        admin-debug = pkgs.runCommand "admin-debug" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
        } ''
          set -euo pipefail
          OUT=$out
          fail() { echo "FAIL: $*" >&2; exit 1; }
          work="$TMPDIR/admin-debug"; mkdir -p "$work/xdg/testcode"
          export XDG_CONFIG_HOME="$work/xdg" HOME="$work"
          CANARY='sk-CANARY-DO-NOT-PRINT'
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          W=${defaultWrapper}/bin/testcode
          printf 'x %s\n' "$CANARY" > "$work/control.txt"
          grep -q "$CANARY" "$work/control.txt" || fail "canary detector broken"

          set +e; err=$(SHMULCODE_DEBUG=1 STUB_EXIT=0 "$W" 2>&1 >/dev/null); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "debug run rc $rc"
          echo "$err" | grep -q 'debug: resolved' || fail "debug trace missing"
          echo "$err" | grep -q "$work/xdg/testcode/env" || fail "debug trace path missing"
          echo "$err" | grep -q 'mode 600' || fail "debug trace mode missing"
          if echo "$err" | grep -q "$CANARY"; then fail "debug trace leaked canary"; fi

          set +e; err=$(STUB_EXIT=0 "$W" 2>&1 >/dev/null); set -e
          if echo "$err" | grep -q 'debug: resolved'; then fail "debug trace emitted without SHMULCODE_DEBUG"; fi
          touch "$OUT"
        '';

        # DIST-06: `nix run .#mimocode -- --version` delivers `--version` to the
        # program (Nix consumes its own `--` separator). A literal `--` passed
        # directly to the wrapper is also forwarded unchanged by `exec "$@"`.
        passthrough = pkgs.runCommand "passthrough" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
        } ''
          set -euo pipefail
          OUT=$out
          work="$TMPDIR/pass"; mkdir -p "$work/xdg/mimocode"
          cp ${validEnv} "$work/xdg/mimocode/env"; chmod 600 "$work/xdg/mimocode/env"
          export XDG_CONFIG_HOME="$work/xdg" HOME="$work"
          W=${stubLaunchers.mimocode}/bin/mimocode

          got=$("$W" --version 2>/dev/null) || { echo "FAIL: wrapper exited $? for --version" >&2; exit 1; }
          echo "$got" | grep -q 'STUB-ARGV: --version' || { echo "FAIL: --version not forwarded: $got" >&2; exit 1; }

          got=$("$W" -- --version 2>/dev/null) || { echo "FAIL: wrapper exited $? for -- --version" >&2; exit 1; }
          echo "$got" | grep -q 'STUB-ARGV: -- --version' || { echo "FAIL: literal -- not forwarded: $got" >&2; exit 1; }

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

          # CR-02a: ambient SHELLOPTS=xtrace must not trace assignments.
          printf 'ANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          set +e; diag=$(env SHELLOPTS=xtrace STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 0 ] || fail "SEC-03 xtrace run rc ($rc)"
          echo "$diag" | grep -q "$CANARY" && fail "SEC-03 CR-02 canary leaked via ambient xtrace"

          # CR-02b: a `set -x` inside the env file is rejected outright (78) —
          # it cannot be outrun, since it takes effect mid-file.
          printf 'set -x\nANTHROPIC_BASE_URL=https://example.test\nANTHROPIC_AUTH_TOKEN=%s\n' "$CANARY" > "$work/xdg/testcode/env"
          chmod 600 "$work/xdg/testcode/env"
          set +e; diag=$(STUB_EXIT=0 "$W" 2>&1); rc=$?; set -e
          [ "$rc" -eq 78 ] || fail "SEC-03 in-file set -x rc ($rc, want 78)"
          echo "$diag" | grep -q "$CANARY" && fail "SEC-03 CR-02 canary leaked via in-file set -x"
          echo "$diag" | grep -q 'enables shell tracing' || fail "SEC-03 tracing rejection not reported"
          pass "SEC-03 no values in diagnostics"

          touch "$OUT"
        '';

        # HMOD-01..05/07 (eval): option schema, store-prefix and charset guards,
        # mechanism agnosticism, explicit enable, and command rename. Every
        # must-fail probe is paired with a must-succeed canary; the result JSON
        # is written only when every probe has the expected outcome.
        hm-module-results =
          let
            r = hmResults;
            ok =
              r.goodActivates
              && builtins.elem "mimocode" r.goodPackages
              && builtins.elem "grok" r.goodPackages
              && r.builtinsAreDeclared && r.zeroHasNoLaunchers
              && r.disabledOnlyHasNoLaunchers
              && r.storeFails
              && r.emptyFails
              && r.badCommandFails
              && r.badVarsFails
              && r.badPathFails
              && r.duplicateCommandsFail
              && r.reservedCommandFails
              && r.agenixRefEvaluates;
          in
          if ok
          then pkgs.writeText "hm-module-results" (builtins.toJSON r)
          else throw "hm-module-results: unexpected outcome: ${builtins.toJSON r}";

        # HMOD-03/05/06 (build): build a REAL Home Manager activation package
        # with the module and a stub claude, then assert the baked path reached
        # the generated script, the baked branch has no fallback, and the
        # renamed instance kept the instance-name path/hint.
        hm-module-activation = pkgs.runCommand "hm-module-activation" {
          nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
        } ''
          set -euo pipefail
          OUT=$out
          fail() { echo "FAIL: $*" >&2; exit 1; }
          G=${hmGood.activationPackage}

          # Baked instance: path present, no runtime fallback branches.
          W="$G/home-path/bin/mimocode"
          test -x "$W" || fail "activation lacks home-path/bin/mimocode"
          grep -qE 'exec /nix/store/[^ "]+/bin/claude' "$W" || fail "wrapper does not exec an absolute claude path"
          if grep -qE 'exec /nix/store/[^ "]+claude-code[^ "]*/bin/claude' "$W"; then
            fail "wrapper execs the real claude-code package, not the stub"
          fi
          grep -qF 'env_file="/run/agenix/mimocode-env"' "$W" || fail "baked env path missing from wrapper"
          grep -qF 'origin="baked path"' "$W" || fail "baked origin label missing from wrapper"
          if grep -qF 'XDG_CONFIG_HOME' "$W"; then fail "baked wrapper contains an XDG fallback"; fi
          if grep -qF 'HOME/.config' "$W"; then fail "baked wrapper contains a HOME fallback"; fi

          # Renamed runtime-resolution instance: envName keeps the instance name.
          R="$G/home-path/bin/grok"
          test -x "$R" || fail "activation lacks the renamed home-path/bin/grok"
          if test -e "$G/home-path/bin/grokcode"; then fail "rename left a grokcode binary"; fi
          if test -e "$G/home-path/bin/claude"; then fail "bare claude was installed into home.packages"; fi
          grep -qF 'XDG_CONFIG_HOME' "$R" || fail "positive control: runtime wrapper lacks XDG branch"
          grep -qF '.config/grokcode/env' "$R" || fail "renamed wrapper path segment is not the instance name"
          grep -qF 'shmulcode init grokcode' "$R" || fail "renamed wrapper init hint is not the instance name"
          if grep -qF '.config/grok/env' "$R"; then
            fail "renamed wrapper path followed command instead of the instance name"
          fi

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
          # CR-01: fail closed. grep exits 0 = match (leak), 1 = clean,
          # 2 = could not scan (e.g. a missing target) — 2 must never read clean.
          rc=0
          grep -rnE "$pattern" ${../lib} ${./pkgs.nix} ${./packages.nix} ${./admin.nix} \
            ${./_instances.nix} ${./home-manager.nix} ${../flake.nix} || rc=$?
          case "$rc" in
            0) echo "SEC-01 FAIL: eval-time secret access found above" >&2; exit 1 ;;
            1) : ;;
            *) echo "SEC-01 ERROR: lint could not scan its targets (grep exit $rc)" >&2; exit 1 ;;
          esac
          touch "$out"
        '';
      };
    };
}
