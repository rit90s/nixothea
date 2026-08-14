# A constructor: `nixothea.targets.aur { }` returns a target that produces
# a PKGBUILD -- AUR packages are metadata plus a build recipe makepkg runs
# later, externally, on a real Arch machine (which is what actually
# fetches sources and installs dependencies via pacman) -- nixothea never
# builds the real software for this target, only generates the recipe.
#
# A package definition may set `aurSource`/`aurSourceSha256` (plain string
# attrs alongside pname/version/meta/buildPhase/installPhase on the
# pkgs.mkDerivation call) to get a real source=()/sha256sums=() pair in the
# generated PKGBUILD, fetched for real by makepkg on the Arch machine --
# see builder.nix. Without them, `build()` still runs against an empty
# $srcdir, same as before this existed: only meaningful for definitions
# that need no external source (as all the other targets' tests in this
# repo do).
#
# Known limitations, kept out of scope for this pass:
#   - only a single source entry -- no multiple sources, no local
#     patch-style companion files shipped alongside the PKGBUILD;
#   - the sha256 has to come from the caller -- nixothea has no impure
#     phase for the root package's own source the way `resolve` is for
#     declared dependencies, so it can't fetch-and-hash this itself;
#   - no makedepends= -- nativeBuildInputs stays real Nix build tooling
#     (see wrap-mk-derivation.nix), which isn't meaningful to write into a
#     PKGBUILD meant to run on a real Arch machine;
#   - pkgname/pkgver aren't validated against PKGBUILD's charset rules.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;
in
{
  # PKGBUILD header comment, e.g. "Name <email>". Omitted when null.
  maintainer ? null,

  # Incremented independently of pkgver when only the packaging (not the
  # underlying software) changes.
  pkgrel ? 1,

  arch ? [ "x86_64" ],
}:
mkTarget {
  inherit pkgs lib;
  resolve = import ./resolver.nix { inherit lib; };
  inherit (import ./builder.nix { inherit lib collectDeps maintainer pkgrel arch; })
    nativeDerivationFactory mkDerivation;
}
