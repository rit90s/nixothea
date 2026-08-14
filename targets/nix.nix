# A constructor: `nixothea.targets.nix { }` returns a target that's
# completely transparent -- built packages are exactly the derivation
# pkgs.mkDerivation would have produced natively, with no repackaging of
# any kind. Useful as a baseline/control, and for definitions that don't
# need anything target-specific from the "nix" leg of a multi-target build.
{ pkgs, mkTarget, targetImpl }:
let
  lib = pkgs.lib;
in
{ }:
mkTarget {
  inherit pkgs lib;

  # Nothing to resolve against a live registry -- nixpkgs attribute names
  # are already fully pinned by the nixpkgs revision in use -- so this
  # just echoes the declared dependency spec back as the lock section,
  # unchanged.
  resolve = targetImpl.resolvers.passthrough "nix";

  # entry.name is a real nixpkgs attribute name (top-level only; no
  # dotted-path lookup for nested attrsets like python3Packages.foo).
  nativeDerivationFactory = { pkgs, name, entry }:
    pkgs.${entry.name} or
      (throw "nixothea nix target: no such nixpkgs package '${entry.name}' (for dependency '${name}')");

  # Transparent: regardless of role, the real derivation *is* the result --
  # no wrapping, no merging, exactly what pkgs.mkDerivation would have
  # produced natively.
  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }: realDrv;
}
