# Unit tests for lib/wrap-mk-derivation.nix -- the node semantics every
# target's `pkgs.mkDerivation` is built on: buildInputs validation,
# unwrapping nodes to their real derivation, dropping metadata-only
# dependencies from the real build while still exposing them structurally,
# deduplicating nested nodes, and leaving nativeBuildInputs alone. Uses
# fixtures.mkFakeTarget so these assertions are about the generic
# machinery, not any one real target's packaging policy.
{ pkgs, fixtures }:
let
  target = fixtures.mkFakeTarget { };
  tpkgs = fixtures.mkTargetPkgs target;

  depA = fixtures.mkFakeDependency { name = "depA"; };
  depAAgain = fixtures.mkFakeDependency { name = "depA"; }; # same logical name, separate value
  metaOnlyDep = fixtures.mkFakeDependency { name = "metaOnly"; hasRealDrv = false; };

  leaf = tpkgs.mkDerivation { pname = "leaf"; version = "1"; buildInputs = [ ]; };
  # Same pname/version as `leaf`, but a distinct MARKER env var -- still a
  # genuinely distinct drvPath (two structurally identical
  # stdenv.mkDerivation calls produce the exact same drvPath, so an
  # identical copy of `leaf` would NOT be a useful "two distinct nodes"
  # fixture).
  leafAgain = tpkgs.mkDerivation { pname = "leaf"; version = "1"; buildInputs = [ ]; MARKER = "leafAgain"; };
in
[
  {
    name = "a node in buildInputs is exposed via nodeDeps, not dependencyDeps";
    expr =
      let n = tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ leaf ]; };
      in [ (map (x: x.realDrv.pname) n.nodeDeps) n.dependencyDeps ];
    expected = [ [ "leaf" ] [ ] ];
  }
  {
    name = "a resolved dependency in buildInputs is exposed via dependencyDeps, not nodeDeps";
    expr =
      let n = tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ depA ]; };
      in [ n.nodeDeps (map (d: d._nixotheaDependencyName) n.dependencyDeps) ];
    expected = [ [ ] [ "depA" ] ];
  }
  {
    name = "nodes reached via buildInputs and propagatedBuildInputs are merged and deduped together";
    expr =
      let
        n = tpkgs.mkDerivation {
          pname = "p"; version = "1";
          buildInputs = [ leaf ];
          propagatedBuildInputs = [ leaf ]; # same node, reached twice
        };
      in
      builtins.length n.nodeDeps;
    expected = 1;
  }
  {
    name = "two distinct nodes (different drvPath) with the same pname are not deduped";
    expr =
      let n = tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ leaf leafAgain ]; };
      in builtins.length n.nodeDeps;
    expected = 2;
  }
  {
    name = "two dependencyDeps entries under the same logical name are both kept (dedup is collectDeps' job, not this node's)";
    expr =
      let n = tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ depA depAAgain ]; };
      in builtins.length n.dependencyDeps;
    expected = 2;
  }
  {
    name = "a metadata-only dependency (no outPath) still appears in dependencyDeps";
    expr =
      let n = tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ metaOnlyDep ]; };
      in map (d: d._nixotheaDependencyName) n.dependencyDeps;
    expected = [ "metaOnly" ];
  }
  {
    name = "a metadata-only dependency doesn't prevent construction (dropped from the real stdenv.mkDerivation call)";
    expr = (tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ metaOnlyDep ]; }) ? outPath;
    expected = true;
  }
  {
    name = "a plain, untagged value in buildInputs throws";
    expr = tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ "just a string" ]; };
    throws = true;
  }
  {
    name = "a plain, untagged value in propagatedBuildInputs throws";
    expr = tpkgs.mkDerivation { pname = "p"; version = "1"; propagatedBuildInputs = [ { } ]; };
    throws = true;
  }
  {
    name = "a plain, untagged value in nativeBuildInputs does NOT throw (build-time-only, left untouched)";
    expr = (tpkgs.mkDerivation { pname = "p"; version = "1"; nativeBuildInputs = [ { } ]; }) ? outPath;
    expected = true;
  }
  {
    name = "calling the node as a function dispatches to the target's mkDerivation with the right role/name and merged deps";
    expr =
      let
        n = tpkgs.mkDerivation { pname = "p"; version = "1"; buildInputs = [ leaf depA ]; };
        called = n { role = "dependency"; name = "p"; };
      in
      [ called.fakeRole called.fakeName called.fakeNodeNames called.fakeDependencyNames ];
    expected = [ "dependency" "p" [ "leaf" ] [ "depA" ] ];
  }
]
