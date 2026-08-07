# Phase 2: build.
#
# `targets` is the same explicit, caller-controlled attrset passed to
# `mkResolver`: { <targetName> = <target module>; }. For each one: turns
# its already-resolved dependencies (found under `.targets.<name>` in the
# lock file at `lockFile`) into real `pkgs.<logicalName>` values via that
# target's `nativeDerivationFactory` (called once per dependency, tagged
# with the logical name it was resolved under -- see collect-deps.nix,
# which dedupes by this since not every dependency has a real derivation
# to identify it by), builds a
# `pkgs` out of those plus that target's own `mkDerivation` (see
# wrap-mk-derivation.nix -- this is the framework-provided, generic
# `pkgs.mkDerivation`, not the target's raw one), evaluates `definition`
# (a function `{ pkgs }: pkgs.mkDerivation { ... }`, written once and
# reused across every target) against it, and realizes the result as the
# root of the package.
#
# Returns { <targetName> = <packaged derivation>; }, one per target in
# `targets`. Nix is lazy, so nothing is actually built until a specific
# attribute (e.g. `.debian`) is accessed.
{ targets, pkgs, lockFile, definition }:
let
  lib = pkgs.lib;
  lock = builtins.fromJSON (builtins.readFile lockFile);
in
lib.mapAttrs
  (targetName: target:
    let
      lockSection = lock.targets.${targetName} or { };

      customDeps = lib.mapAttrs
        (depName: entry:
          (target.nativeDerivationFactory { inherit pkgs; name = depName; inherit entry; })
          // { _nixotheaDependency = true; _nixotheaDependencyName = depName; })
        lockSection;

      customPkgs = customDeps // {
        mkDerivation = import ./wrap-mk-derivation.nix { inherit pkgs target; };
      };

      result = definition { pkgs = customPkgs; };
    in
    if !(result._nixotheaNode or false) then
      throw "nixothea: definition must return the result of pkgs.mkDerivation"
    else
      result { role = "root"; })
  targets
