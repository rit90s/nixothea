# Phase 2: build.
#
# `targets` is the same explicit, caller-controlled attrset passed to
# `mkResolver`: { <targetName> = <target module>; }. Each target carries
# its own `pkgs` (fixed when it was constructed -- see mk-target.nix), so
# `targets` here can freely mix targets that need fundamentally different
# pkgs (e.g. `deb` alongside `windowsExe`) in one call -- `definition`
# still gets evaluated once per target, each time against that target's
# own real pkgs, so the same target-agnostic `definition` genuinely
# compiles differently (or not at all, for recipe-only targets) as
# appropriate per target, with no extra work from the caller. For each
# target: turns its already-resolved dependencies (found under
# `.targets.<name>` in the lock file at `lockFile`) into real
# `pkgs.<logicalName>` values via that target's `nativeDerivationFactory`
# (called once per dependency, tagged with the logical name it was
# resolved under -- see collect-deps.nix, which dedupes by this since not
# every dependency has a real derivation to identify it by), builds a
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
{ targets, lockFile, definition }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);
in
# builtins.mapAttrs, not lib.mapAttrs: there's no single shared `pkgs` to
# borrow a `lib` from up here anymore -- each target below reaches for
# its own `pkgs.lib` instead, once it's in scope.
builtins.mapAttrs
  (targetName: target:
    let
      pkgs = target.pkgs;
      lib = pkgs.lib;
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
