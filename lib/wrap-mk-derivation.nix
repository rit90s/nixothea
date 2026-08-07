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
#   - deduplicates repeated nested nodes by drvPath -- the same identity
#     Nix's own store already uses, so e.g. two derivations describing the
#     same closure inputs collapse even if reached via different paths;
#   - leaves nativeBuildInputs/propagatedNativeBuildInputs completely
#     untouched: they're build-time-only tools, not part of the package's
#     runtime shape, and nodes already behave as real derivations there
#     with no unwrapping needed;
#   - constructs the real underlying `pkgs.stdenv.mkDerivation` call.
{ pkgs, target }:
let
  lib = pkgs.lib;

  isNode = x: x._nixotheaNode or false;
  isDependency = x: x._nixotheaDependency or false;

  # Real value to hand the real stdenv.mkDerivation for actual
  # compiling/linking against.
  unwrap = attrName: x:
    if isNode x then x.realDrv
    else if isDependency x then x
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

  realArgs = args // {
    buildInputs = map (unwrap "buildInputs") (args.buildInputs or [ ]);
    propagatedBuildInputs = map (unwrap "propagatedBuildInputs") (args.propagatedBuildInputs or [ ]);
  };

  realDrv = pkgs.stdenv.mkDerivation realArgs;
in
# `realDrv // {...}` -- still a genuine derivation, so plain old
# `${core}` / `buildInputs = [ core ]` from code that knows nothing about
# nixothea just works, unmodified. nodeDeps/dependencyDeps are exposed
# directly (not just threaded through __functor) so a target's merge logic
# can walk the tree structurally -- see collect-deps.nix -- without having
# to invoke another node's target-specific mkDerivation policy just to see
# what it's made of.
realDrv // {
  _nixotheaNode = true;
  inherit realDrv nodeDeps dependencyDeps;
  __functor = self: { role, name ? null }:
    target.mkDerivation { inherit pkgs role name realDrv nodeDeps dependencyDeps; };
}
