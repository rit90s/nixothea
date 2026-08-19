# Unit tests for lib/collect-deps.nix -- recursively walking nodeDeps,
# deduplicating nodes by drvPath and dependencies by logical name.
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  collectDeps = import ../../lib/collect-deps.nix;

  target = fixtures.mkFakeTarget { };
  tpkgs = fixtures.mkTargetPkgs target;

  depX = fixtures.mkFakeDependency { name = "x"; };
  depXAgain = fixtures.mkFakeDependency { name = "x"; }; # same logical name, different value

  # A genuine diamond: `shared` is reached through both `left` and
  # `right`, which both sit under `root`.
  shared = tpkgs.mkDerivation { pname = "shared"; version = "1"; buildInputs = [ depX ]; };
  left = tpkgs.mkDerivation { pname = "left"; version = "1"; buildInputs = [ shared ]; };
  right = tpkgs.mkDerivation { pname = "right"; version = "1"; buildInputs = [ shared depXAgain ]; };
  root = tpkgs.mkDerivation { pname = "root"; version = "1"; buildInputs = [ left right ]; };
in
[
  {
    name = "a diamond (shared reached via both left and right) collapses to one node";
    expr =
      let result = collectDeps { inherit lib; nodes = root.nodeDeps; };
      in builtins.length (lib.filter (n: n.realDrv.pname == "shared") result.nodes);
    expected = 1;
  }
  {
    name = "every transitively reachable node is included, by name";
    expr =
      let result = collectDeps { inherit lib; nodes = root.nodeDeps; };
      in lib.sort (a: b: a < b) (map (n: n.realDrv.pname) result.nodes);
    expected = [ "left" "right" "shared" ];
  }
  {
    name = "the starting nodes themselves are included, not just their children";
    expr =
      let result = collectDeps { inherit lib; nodes = [ root ]; };
      in builtins.elem "root" (map (n: n.realDrv.pname) result.nodes);
    expected = true;
  }
  {
    name = "a dependency (x) reached under the same logical name from two different nodes dedupes to one entry";
    expr =
      let result = collectDeps { inherit lib; nodes = root.nodeDeps; };
      in builtins.length (lib.filter (d: d._nixotheaDependencyName == "x") result.dependencies);
    expected = 1;
  }
  {
    name = "collectDeps on an empty node list returns empty nodes/dependencies";
    expr =
      let result = collectDeps { inherit lib; nodes = [ ]; };
      in [ result.nodes result.dependencies ];
    expected = [ [ ] [ ] ];
  }
]
