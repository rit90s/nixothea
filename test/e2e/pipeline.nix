# End-to-end test of the real two-phase pipeline against two real,
# pre-implemented targets (`nix` and `aur` -- chosen because both are
# network-free: `nix` resolves against the already-pinned nixpkgs
# revision, `aur` is pure metadata, so this runs safely inside the Nix
# build sandbox with no network access needed) at once, exercising real
# `resolve`/`buildTarget`, real `collectDeps` (via aur's own `mkDerivation`,
# which calls it for real to build one combined PKGBUILD), and a genuine
# diamond: `shared` is reached through both `core` and `utils`, and `ssl`
# is declared both directly on the root *and* nested under `core`.
#
# The lock file below is hand-crafted (`builtins.toFile`) rather than
# produced by actually running `resolve` and feeding its output back into
# `buildTarget` within this same evaluation -- that round-trip needs
# import-from-derivation (build resolve's output, then re-evaluate Nix
# against what it wrote), which doesn't play well with `nix flake check`'s
# sandboxing. Instead, both halves are verified independently, for real,
# in the one script below: `resolve`'s generated script is actually run
# and its JSON diffed against this exact hand-crafted content (proving
# resolve produces it for real), and `buildTarget` is given the
# hand-crafted content directly (proving the build half consumes it
# correctly) -- together, equivalent coverage to the full round-trip,
# without needing IFD.
{ pkgs, nixTarget, aurTarget }:
let
  lib = pkgs.lib;
  mkResolver = import ../../lib/resolver.nix;
  buildTarget = import ../../lib/build.nix;

  dependencies = {
    compression.nix = { name = "zlib"; };
    compression.aur = { name = "zlib"; };
    net.nix = { name = "curl"; };
    net.aur = { name = "curl"; };
    ssl.nix = { name = "openssl"; };
    ssl.aur = { name = "openssl"; };
  };
  myTargets = { nix = nixTarget; aur = aurTarget; };

  expectedLock = {
    targets = {
      nix = { compression = { name = "zlib"; }; net = { name = "curl"; }; ssl = { name = "openssl"; }; };
      aur = { compression = { name = "zlib"; }; net = { name = "curl"; }; ssl = { name = "openssl"; }; };
    };
  };
  lockFile = builtins.toFile "pipeline-lock.json" (builtins.toJSON expectedLock);

  definition = { pkgs }:
    let
      shared = pkgs.mkDerivation {
        pname = "shared"; version = "1.0";
        dontUnpack = true;
        buildInputs = [ pkgs.compression ];
        buildPhase = "echo shared-marker";
        installPhase = "mkdir -p $out";
      };
      core = pkgs.mkDerivation {
        pname = "core"; version = "1.0";
        dontUnpack = true;
        buildInputs = [ shared pkgs.ssl ]; # `ssl` also reachable directly from root below
        buildPhase = "true";
        installPhase = "mkdir -p $out";
      };
      utils = pkgs.mkDerivation {
        pname = "utils"; version = "1.0";
        dontUnpack = true;
        buildInputs = [ shared pkgs.net ]; # `shared` reached a second time -- the diamond
        buildPhase = "true";
        installPhase = "mkdir -p $out";
      };
    in
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildInputs = [ core utils pkgs.ssl ];
      meta.description = "nixothea e2e pipeline fixture";
      buildPhase = "true";
      installPhase = ''
        mkdir -p $out/bin
        printf '#!/bin/sh\necho hello\n' > $out/bin/hello
        chmod +x $out/bin/hello
      '';
    };

  resolveScript = mkResolver { inherit dependencies; targets = myTargets; };
  built = buildTarget { targets = myTargets; inherit lockFile definition; };
in
pkgs.runCommand "nixothea-test-e2e-pipeline"
  {
    resolveScript = lib.getExe resolveScript;
    helloNix = built.nix;
    helloAur = built.aur;
    expectedLockJson = builtins.toFile "expected-lock.json" (builtins.toJSON expectedLock);
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    # 1. resolve, run for real, produces exactly the hand-crafted lock
    #    content above (proves the "nix"/"aur" resolvers really are
    #    transparent/passthrough, not just by reading their source).
    "$resolveScript" --out actual-lock.json
    jq -S . actual-lock.json > actual-sorted.json
    jq -S . "$expectedLockJson" > expected-sorted.json
    if ! diff -u expected-sorted.json actual-sorted.json; then
      echo "FAIL: real resolve output didn't match the hand-crafted lock content" >&2
      exit 1
    fi

    # 2. the real "nix" target build: a genuine derivation, real zlib/curl/
    #    openssl linked in as buildInputs, runs for real.
    if [ ! -x "$helloNix/bin/hello" ]; then
      echo "FAIL: $helloNix/bin/hello missing or not executable" >&2
      exit 1
    fi
    helloOutput=$("$helloNix/bin/hello")
    if [ "$helloOutput" != "hello" ]; then
      echo "FAIL: hello (nix target) printed '$helloOutput', expected 'hello'" >&2
      exit 1
    fi

    # 3. the real "aur" target build: one combined, real PKGBUILD.
    #    `depends=` must list each logical dependency's real name exactly
    #    once, even though `ssl` is reachable both directly from root and
    #    nested under `core` -- proves buildTarget/collectDeps' real
    #    dedup-by-logical-name, not a fake one.
    if ! grep -qF 'depends=(zlib curl openssl)' "$helloAur/PKGBUILD"; then
      echo "FAIL: PKGBUILD depends= line missing or wrong (expected each of zlib/curl/openssl exactly once)" >&2
      cat "$helloAur/PKGBUILD" >&2
      exit 1
    fi

    # 4. `shared` is reached twice (via both core and utils) but must only
    #    contribute its buildPhase once -- proves collectDeps' real
    #    node-level (drvPath) dedup, not just the dependency-level one
    #    above.
    marker_count=$(grep -c 'shared-marker' "$helloAur/PKGBUILD")
    if [ "$marker_count" -ne 1 ]; then
      echo "FAIL: shared's buildPhase appears $marker_count times in the combined PKGBUILD, expected exactly 1" >&2
      cat "$helloAur/PKGBUILD" >&2
      exit 1
    fi

    echo "nixothea-test-e2e-pipeline: passed" | tee $out
  ''
