# Unit tests for utils/debug/referenced-dependency-names.nix -- flat,
# deduplicated logical dependency names referenced anywhere in a node
# tree, root included.
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  referencedDependencyNames = import ../../utils/debug/referenced-dependency-names.nix;

  target = fixtures.mkFakeTarget { };
  tpkgs = fixtures.mkTargetPkgs target;

  depX = fixtures.mkFakeDependency { name = "x"; };
  depXAgain = fixtures.mkFakeDependency { name = "x"; };
  depY = fixtures.mkFakeDependency { name = "y"; };

  child = tpkgs.mkDerivation { pname = "child"; version = "1"; buildInputs = [ depY ]; };
  root = tpkgs.mkDerivation { pname = "root"; version = "1"; buildInputs = [ child depX depXAgain ]; };
in
[
  {
    name = "includes the root's own direct dependencyDeps, not just nested nodes' ones";
    expr = lib.sort (a: b: a < b) (referencedDependencyNames { inherit lib; tree = root; });
    expected = [ "x" "y" ];
  }
  {
    name = "two references under the same logical name (root's own two `x` entries) dedupe to one";
    expr = builtins.length (lib.filter (n: n == "x") (referencedDependencyNames { inherit lib; tree = root; }));
    expected = 1;
  }
  {
    name = "a leaf node with no dependencies at all returns []";
    expr = referencedDependencyNames { inherit lib; tree = tpkgs.mkDerivation { pname = "leaf"; version = "1"; buildInputs = [ ]; }; };
    expected = [ ];
  }
]
