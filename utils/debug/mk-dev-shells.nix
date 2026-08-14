# For debugging/developing an app against one target's real native
# dependencies, locally, via `nix develop .#<targetName>` -- not part of
# the resolve/build pipeline itself (see lib/resolver.nix, lib/build.nix).
# Deliberately mirrors buildTarget's own shape (`{ targets, lockFile,
# definition }`, one result per key in `targets`, reading the very same
# lock file `resolve` already produced) so a caller can wire this in
# right alongside `packages.${system}` with nothing new to learn -- see
# lib/build.nix.
#
# Two differences from buildTarget's own `definition`, both intentional:
#
#   - `pkgs` here is the target's own real, full `pkgs` (`target.pkgs`
#     itself) -- not buildTarget's restricted wrapper (only resolved
#     deps plus `mkDerivation`, see lib/wrap-mk-derivation.nix). A
#     devShell isn't a packaged output bound by nixothea's own
#     portability rules (a *package* needs every dependency to flow
#     through the declared-dependency pipeline for real reproducibility)
#     -- so there's no reason to hide the rest of nixpkgs from someone
#     debugging locally: pkgs.gdb, pkgs.valgrind, anything else, are all
#     just there, exactly like a normal `pkgs.mkShell` call would have.
#
#   - `buildInputs` is a plain list, already filtered down to only the
#     dependencies that actually have a real derivation to offer (the
#     same has-a-real-`outPath` check wrap-mk-derivation.nix's `unwrap`
#     already does for a real build). A metadata-only target
#     (`aur`/`homebrew`/`flatpak`: dependencies are just names for a
#     recipe some *other* tool resolves later, nothing nixothea itself
#     ever fetches) simply contributes nothing here rather than
#     erroring -- the shell still builds, using that target's own real
#     toolchain, just without extra buildInputs. The whole point is
#     debugging the packaging process as close to the real thing as
#     possible, and a real build already drops these dependencies the
#     exact same way.
#
# `definition` defaults to the trivial case (just a shell with the
# resolved buildInputs available), but is a normal function like
# buildTarget's own -- a caller can do anything a hand-written
# `pkgs.mkShell { ... }` could (extra packages, a shellHook, env vars,
# ...) by simply passing their own `{ pkgs, buildInputs }: pkgs.mkShell { ... }`.
{
  targets,
  lockFile,
  definition ? ({ pkgs, buildInputs }: pkgs.mkShell { inherit buildInputs; }),
}:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);
in
# builtins.mapAttrs, not lib.mapAttrs -- same reasoning as lib/build.nix:
# there's no single shared `lib` available before each target's own
# `pkgs` is in scope.
builtins.mapAttrs
  (targetName: target:
    let
      pkgs = target.pkgs;
      lib = pkgs.lib;
      lockSection = lock.targets.${targetName} or { };

      nativeValues = lib.mapAttrsToList
        (depName: entry: target.nativeDerivationFactory { inherit pkgs; name = depName; inherit entry; })
        lockSection;

      # Only what's actually a real, buildable derivation -- see the
      # header comment above.
      buildInputs = builtins.filter (v: v ? outPath) nativeValues;
    in
    definition { inherit pkgs buildInputs; })
  targets
