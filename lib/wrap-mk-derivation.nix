# The generic, shared implementation behind every target's exposed
# `pkgs.mkDerivation`. Handles the mechanical parts common to every target,
# so each target only has to implement the part that's actually
# target-specific: what a root node becomes, and what a node being merged
# into something else becomes (see mk-target.nix).
#
# Specifically, this:
#   - requires buildInputs/propagatedBuildInputs to contain only values
#     this framework itself produced (nixothea nodes, from pkgs.mkDerivation,
#     or nixothea dependencies, from a resolved lock entry) -- anything
#     else throws, since there'd be no defined way to represent it in the
#     final package;
#   - unwraps nodes to their real derivation so the real build can actually
#     compile/link against them;
#   - drops dependencies that have no real derivation (e.g. an AUR target's,
#     which are pure metadata -- see aur.nix) from the real build instead of
#     handing stdenv.mkDerivation a non-derivation value, which would fail
#     at construction time. This is safe precisely because such a target
#     never actually realizes this real build -- it only reads its cheap
#     metadata (pname, version, buildPhase text, ...) -- so there's nothing
#     sensible for it to link against in the first place;
#   - deduplicates repeated nested nodes by drvPath -- the same identity
#     Nix's own store already uses, so e.g. two derivations describing the
#     same closure inputs collapse even if reached via different paths;
#   - leaves nativeBuildInputs/propagatedNativeBuildInputs completely
#     untouched: they're build-time-only tools, not part of the package's
#     runtime shape, and nodes already behave as real derivations there
#     with no unwrapping needed (and a metadata-only dependency placed
#     there is a genuine error, not something this papers over -- a Nix
#     build tool isn't a meaningful thing for e.g. an AUR makedepends
#     entry anyway);
#   - constructs the real underlying `pkgs.stdenv.mkDerivation` call.
{ pkgs, target }:
let
  lib = pkgs.lib;

  isNode = x: x._nixotheaNode or false;
  isDependency = x: x._nixotheaDependency or false;

  # Real value to hand the real stdenv.mkDerivation for actual
  # compiling/linking against, or null if there isn't one (filtered out
  # below).
  unwrap = attrName: x:
    if isNode x then x.realDrv
    else if isDependency x then (if x ? outPath then x else null)
    else throw ''
      nixothea: `${attrName}` may only contain nixothea derivations (from
      pkgs.mkDerivation, or a declared dependency) -- got a plain value
      instead. If this needs a normal build dependency, add it to
      nativeBuildInputs instead.'';

  dedupeNodes = nodes:
    builtins.attrValues (builtins.listToAttrs
      (map (n: { name = builtins.unsafeDiscardStringContext n.realDrv.drvPath; value = n; }) nodes));
in
args:
let
  scan = attrName: lib.filter isNode (args.${attrName} or [ ]);
  nodeDeps = dedupeNodes (scan "buildInputs" ++ scan "propagatedBuildInputs");

  dependencyDeps = lib.filter isDependency
    ((args.buildInputs or [ ]) ++ (args.propagatedBuildInputs or [ ]));

  dropUnbuildable = attrName:
    lib.filter (x: x != null) (map (unwrap attrName) (args.${attrName} or [ ]));

  realArgs = args // {
    buildInputs = dropUnbuildable "buildInputs";
    propagatedBuildInputs = dropUnbuildable "propagatedBuildInputs";
  };

  realDrv = pkgs.stdenv.mkDerivation realArgs;
in
# `realDrv // {...}` -- still a genuine derivation, so plain old
# `${core}` / `buildInputs = [ core ]` from code that knows nothing about
# nixothea just works, unmodified. nodeDeps/dependencyDeps/args are
# exposed directly (not just threaded through __functor) so a target's
# merge logic can walk the tree structurally -- see collect-deps.nix --
# without having to invoke another node's target-specific mkDerivation
# policy just to see what it's made of.
realDrv // {
  _nixotheaNode = true;
  inherit realDrv nodeDeps dependencyDeps args;
  __functor = self: { role, name ? null }:
    target.mkDerivation { inherit pkgs role name realDrv nodeDeps dependencyDeps args; };
}
