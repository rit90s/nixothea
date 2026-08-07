# Recursively walks a set of nodes' own nodeDeps, returning everything
# transitively reachable: every nested node (deduplicated by drvPath --
# Nix's own derivation identity) and every nested dependency
# (deduplicated by the logical name it was declared under, since not
# every dependency has a real derivation to identify it by otherwise --
# see build.nix). For targets that need to reason about the whole
# dependency tree, not just what's directly on one node --
# wrap-mk-derivation.nix's nodeDeps/dependencyDeps are single-level only.
{ lib, nodes }:
let
  dedupeBy = key: xs:
    builtins.attrValues (builtins.listToAttrs (map (x: { name = key x; value = x; }) xs));

  nodeKey = n: builtins.unsafeDiscardStringContext n.realDrv.drvPath;
  dependencyKey = d: d._nixotheaDependencyName;

  # Every node transitively reachable from `ns` (including `ns`
  # themselves), deduplicated. Safe to recurse naively without tracking
  # "already visited": derivation graphs can't be cyclic (Nix can't even
  # construct a derivation whose inputs aren't already fully evaluated),
  # so this always terminates -- the only cost of not tracking visited
  # nodes is walking an already-seen subtree's nodeDeps again before the
  # final dedupe collapses it, which is cheap since Nix already memoized
  # each node's own real derivation.
  allNodes = ns:
    dedupeBy nodeKey (ns ++ lib.concatMap (n: allNodes n.nodeDeps) ns);

  reachableNodes = allNodes nodes;
in
{
  nodes = reachableNodes;
  dependencies = dedupeBy dependencyKey
    (lib.concatMap (n: n.dependencyDeps) reachableNodes);
}
