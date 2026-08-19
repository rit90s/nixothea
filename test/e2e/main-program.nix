# End-to-end test of utils/targetImpl/autoDetectMainProgram -- inherently
# an e2e-only concern, not a unit-testable one: it inspects
# `${realDrv}/bin` via `builtins.pathExists`/`readDir`, which only sees
# anything meaningful once `realDrv` is actually built (Nix transparently
# realizes an as-yet-unbuilt derivation on demand when a filesystem
# builtin is used on its output path -- the same import-from-derivation
# mechanism every pre-implemented target relying on this function already
# depends on for real, e.g. tarball/appimage/docker/windowsExe/snap's own
# `mainProgram` auto-detection during a real `nix build`).
#
# Two real fixture derivations (one with exactly one `bin/` entry, one
# with two) are built for real and fed to the function directly, plus one
# full real build through the actual `tarball` target (proving the
# indirect, real-target usage works end to end, not just the function in
# isolation).
{ pkgs, tarballTarget }:
let
  lib = pkgs.lib;
  autoDetectMainProgram = import ../../utils/targetImpl/auto-detect-main-program.nix;
  buildTarget = import ../../lib/build.nix;

  oneEntryDrv = pkgs.stdenv.mkDerivation {
    pname = "hello"; version = "1.0";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      printf '#!/bin/sh\necho hi\n' > $out/bin/hello
      chmod +x $out/bin/hello
    '';
  };
  twoEntryDrv = pkgs.stdenv.mkDerivation {
    pname = "ambiguous"; version = "1.0";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      printf '#!/bin/sh\n' > $out/bin/a
      printf '#!/bin/sh\n' > $out/bin/b
      chmod +x $out/bin/a $out/bin/b
    '';
  };

  detected = autoDetectMainProgram {
    inherit lib; targetName = "test"; realDrv = oneEntryDrv; mainProgram = null;
  };

  ambiguousThrew = !(builtins.tryEval (builtins.deepSeq
    (autoDetectMainProgram { inherit lib; targetName = "test"; realDrv = twoEntryDrv; mainProgram = null; })
    true)).success;

  emptyLock = builtins.toFile "main-program-lock.json" (builtins.toJSON { targets = { }; });
  built = buildTarget {
    targets.tb = tarballTarget;
    lockFile = emptyLock;
    definition = { pkgs }:
      pkgs.mkDerivation {
        pname = "hello"; version = "1.0";
        dontUnpack = true;
        buildPhase = "true";
        installPhase = ''
          mkdir -p $out/bin
          printf '#!/bin/sh\necho hi\n' > $out/bin/hello
          chmod +x $out/bin/hello
        '';
      };
  };
in
if detected != "hello" then
  throw "nixothea e2e main-program: expected \"hello\", got ${builtins.toJSON detected}"
else if !ambiguousThrew then
  throw "nixothea e2e main-program: expected a throw for two ambiguous bin/ entries, none happened"
else
  pkgs.runCommand "nixothea-test-e2e-main-program"
    { tarballOut = built.tb; }
    ''
      if ! ls "$tarballOut"/*.tar.gz > /dev/null 2>&1; then
        echo "FAIL: the real tarball target build produced no .tar.gz" >&2
        ls -la "$tarballOut" >&2
        exit 1
      fi
      echo "nixothea-test-e2e-main-program: passed" > $out
    ''
