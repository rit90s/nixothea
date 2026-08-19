# Unit tests for lib/build.nix (buildTarget) -- lock-file-driven
# dependency wiring, the "definition must return a node" guard, missing
# lock sections defaulting to zero dependencies, and per-target laziness.
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  buildTarget = import ../../lib/build.nix;

  goodTarget = fixtures.mkFakeTarget {
    nativeDerivationFactory = { pkgs, name, entry }: entry // { capturedName = name; };
  };
  poisonedTarget = fixtures.mkFakeTarget {
    nativeDerivationFactory = { pkgs, name, entry }: throw "poisonedTarget: should never be evaluated";
  };

  # Same as `goodTarget`, but its mkDerivation exposes the full
  # dependencyDeps objects (not just their logical names) -- only needed
  # for the one test below that inspects an individual entry's fields.
  goodTargetFull = goodTarget // {
    mkDerivation = { pkgs, role, name, realDrv, nodeDeps, dependencyDeps, args }:
      realDrv // { fakeDependencyObjs = dependencyDeps; };
  };

  lockWithDep = builtins.toFile "lock-with-dep.json" (builtins.toJSON {
    targets.good.zlib = { name = "zlib1g-dev"; version = "1.3"; };
  });
  lockWithoutSection = builtins.toFile "lock-empty.json" (builtins.toJSON { targets = { }; });
in
[
  {
    name = "throws when definition doesn't return a nixothea node";
    expr = (buildTarget {
      targets.good = goodTarget;
      lockFile = lockWithoutSection;
      definition = { pkgs }: { just = "a plain attrset"; };
    }).good;
    throws = true;
  }
  {
    name = "a target with no section in the lock file gets zero dependencies, not a throw";
    expr =
      let
        result = (buildTarget {
          targets.good = goodTarget;
          lockFile = lockWithoutSection;
          definition = { pkgs }: pkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ ]; };
        }).good;
      in
      result.fakeDependencyNames;
    expected = [ ];
  }
  {
    name = "the root result is realized with role = \"root\"";
    expr =
      (buildTarget {
        targets.good = goodTarget;
        lockFile = lockWithoutSection;
        definition = { pkgs }: pkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ ]; };
      }).good.fakeRole;
    expected = "root";
  }
  {
    name = "a resolved dependency reaches nativeDerivationFactory with the right logical name, and is tagged/exposed as a dependency";
    expr =
      let
        result = (buildTarget {
          targets.good = goodTarget;
          lockFile = lockWithDep;
          definition = { pkgs }: pkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ pkgs.zlib ]; };
        }).good;
        dep = builtins.head result.fakeDependencyNames;
      in
      dep;
    expected = "zlib";
  }
  {
    name = "the resolved dependency's lock entry (name/version) and the logical name nativeDerivationFactory was called with both flow through to the built node";
    expr =
      let
        result = (buildTarget {
          targets.good = goodTargetFull;
          lockFile = lockWithDep;
          definition = { pkgs }: pkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ pkgs.zlib ]; };
        }).good;
        dep = builtins.head result.fakeDependencyObjs;
      in
      [ dep.name dep.version dep.capturedName ];
    expected = [ "zlib1g-dev" "1.3" "zlib" ];
  }
  {
    name = "accessing one target's result never forces a sibling target's nativeDerivationFactory (per-target laziness)";
    expr =
      (buildTarget {
        targets = { good = goodTarget; bad = poisonedTarget; };
        lockFile = lockWithoutSection;
        definition = { pkgs }: pkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ ]; };
      }).good.fakeRole;
    expected = "root";
  }
]
