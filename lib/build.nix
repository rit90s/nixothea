# Phase 2: build.
#
# `targets` is the same explicit, caller-controlled attrset passed to
# `mkResolver`: { <targetName> = <target module>; }. Evaluates `definition`
# (a function `{ pkgs }: pkgs.mkDerivation { ... }`, written once and
# reused across every target) once per target, using that target's already
# -resolved dependencies found under `.targets.<name>` in the lock file at
# `lockFile`. `definition` only ever sees a `pkgs` containing `mkDerivation`
# (that target's own implementation of it) plus one attribute per logical
# dependency resolved for it.
#
# Returns { <targetName> = <packaged derivation>; }, one per target in
# `targets`. Nix is lazy, so nothing is actually built until a specific
# attribute (e.g. `.debian`) is accessed.
{ targets, pkgs, lockFile, definition }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);
in
pkgs.lib.mapAttrs
  (name: target:
    let
      lockSection = lock.targets.${name} or { };
      customPkgs = lockSection // {
        mkDerivation = target.mkDerivation { inherit pkgs lockSection; };
      };
    in
    definition { pkgs = customPkgs; })
  targets
