# Flat, deduplicated list of every logical dependency name
# (`_nixotheaDependencyName`) referenced anywhere in a constructed node
# tree -- root included, nested nodes at any depth included. `tree` is
# the actual node a target's `definition { pkgs }` produced (see
# lib/wrap-mk-derivation.nix) -- `.nodeDeps`/`.dependencyDeps` are already
# on it directly, which is all `collectDeps` needs to walk it. `lib` is a
# call-time argument, not bound at import time -- same convention as
# lib/collect-deps.nix.
{ lib, tree }:
let
  collectDeps = import ../../lib/collect-deps.nix;
  # `[ tree ]`, not `tree.nodeDeps` -- collectDeps includes the nodes it's
  # given, not just their children, so this also picks up `tree`'s own
  # *direct* dependencyDeps, not only nested nodes' ones.
  collected = collectDeps { inherit lib; nodes = [ tree ]; };
in
# Already deduplicated by this exact key inside collectDeps itself (see
# collect-deps.nix's `dependencyKey`), so no further dedup needed here.
map (d: d._nixotheaDependencyName) collected.dependencies
