# End-to-end test of utils/debug/print-tree.nix: real build, real
# execution of the generated `nixothea-print-tree` script against the
# real `nix` target, for both the text tree and the `--html` graph.
#
# `core`/`utils` are siblings under `hello`, deduplicated (`nodeDeps`) via
# `builtins.listToAttrs`/`attrValues` keyed by drvPath -- real Nix attrset
# iteration is always sorted by *key*, never by insertion order, so which
# of the two actually gets walked (and therefore fully expanded) first
# depends on which one's drvPath happens to sort first, not on
# `buildInputs`' declared order. Both orderings are equally correct
# output from printTree, so this accepts either rather than assuming one
# specific hash ordering (verified for real: this exact fixture produced
# the *other* ordering than doc/utils/debug.md's own example, which uses
# different pnames/versions and therefore different drvPaths).
{ pkgs, nixTarget }:
let
  lib = pkgs.lib;
  printTree = import ../../utils/debug/print-tree.nix;

  myTargets = { nix = nixTarget; };
  lockFile = builtins.toFile "tree-lock.json" (builtins.toJSON {
    targets.nix = {
      compression = { name = "zlib"; version = "1.3"; };
      net = { name = "curl"; version = "8.5.0"; };
      ssl = { name = "openssl"; version = "3.0.13"; };
    };
  });

  definition = { pkgs }:
    let
      core = pkgs.mkDerivation {
        pname = "core"; version = "1.0";
        dontUnpack = true;
        buildInputs = [ pkgs.compression ];
        buildPhase = "true"; installPhase = "mkdir -p $out";
      };
      utils = pkgs.mkDerivation {
        pname = "utils"; version = "1.0";
        dontUnpack = true;
        buildInputs = [ core pkgs.net ];
        buildPhase = "true"; installPhase = "mkdir -p $out";
      };
    in
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildInputs = [ core utils pkgs.ssl ];
      meta.description = "nixothea e2e tree fixture";
      buildPhase = "true";
      installPhase = ''
        mkdir -p $out/bin
        echo x > $out/bin/hello
      '';
    };

  # Variant A: `core` sorts before `utils`, so `core` is fully expanded
  # directly under `hello`, and `utils`' own reference to it collapses to
  # "(see above)".
  expectedTextA = ''
    hello 1.0
      ssl "openssl" 3.0.13
      core 1.0
        compression "zlib" 1.3
      utils 1.0
        net "curl" 8.5.0
        core 1.0 (see above)
  '';
  # Variant B: `utils` sorts before `core`, so `core` is fully expanded
  # nested under `utils` instead, and hello's own direct reference to it
  # collapses to "(see above)".
  expectedTextB = ''
    hello 1.0
      ssl "openssl" 3.0.13
      utils 1.0
        net "curl" 8.5.0
        core 1.0
          compression "zlib" 1.3
      core 1.0 (see above)
  '';

  treeExe = lib.getExe (printTree { targets = myTargets; inherit lockFile definition; });
in
pkgs.runCommand "nixothea-test-e2e-tree"
  {
    inherit treeExe;
    expectedTextFileA = builtins.toFile "expected-tree-a.txt" expectedTextA;
    expectedTextFileB = builtins.toFile "expected-tree-b.txt" expectedTextB;
  }
  ''
    "$treeExe" --target nix > actual.txt
    if ! diff -u "$expectedTextFileA" actual.txt > diffA.txt 2>&1; then
      if ! diff -u "$expectedTextFileB" actual.txt > diffB.txt 2>&1; then
        echo "FAIL: text tree matched neither valid sibling ordering" >&2
        cat diffA.txt diffB.txt >&2
        exit 1
      fi
    fi

    "$treeExe" --target nix --html tree.html
    if ! grep -qF 'nixothea dependency tree: nix' tree.html; then
      echo "FAIL: html output missing expected title" >&2
      exit 1
    fi
    if ! grep -qF '"kind":"dependency"' tree.html; then
      echo "FAIL: html output missing expected embedded graphData" >&2
      exit 1
    fi

    echo "nixothea-test-e2e-tree: passed" > $out
  ''
