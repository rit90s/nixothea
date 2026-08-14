# A constructor: `nixothea.targets.apk { repos = [...]; }` returns a
# target that builds a real .apk, with runtime dependencies fetched as
# real .apk files and extracted during the build -- unlike aur, where a
# dependency is just metadata, here it has to be a real, linkable
# derivation, since the whole point is that the real Nix build (buildPhase
# etc) can actually compile/link against it, the way a real Alpine build
# would. Same overall shape as deb.nix, with one key difference: Alpine is
# musl-based, not glibc-based, so unlike deb/dnf's glibc-to-glibc
# interpreter retarget (a like-for-like swap between two glibc builds),
# this target needs a genuinely musl-linked `realDrv` to retarget in the
# first place -- so this target derives its own musl pkgs (`pkgsMusl`)
# from whatever native pkgs it's constructed with, itself, below, rather
# than requiring the caller to figure out and pass a musl pkgs into
# `buildTarget`/`mkResolver` (see lib/mk-target.nix for why every target
# supplies its own pkgs this way, and windows-exe/default.nix for the
# same pattern applied to a Windows cross pkgs instead). builder.nix's own
# `isMusl` assert stays in place as a defensive backstop, even though
# construction now guarantees it can't actually fail.
{ pkgs, mkTarget, collectDeps }:
let
  # The real pkgs this target builds against.
  alpinePkgs = pkgs.pkgsMusl;
  lib = alpinePkgs.lib;
in
{
  # Where to resolve/fetch packages from -- mandatory, no default, since
  # silently defaulting to some particular Alpine version/mirror is
  # exactly the kind of implicit choice a caller should have to make
  # explicitly (same reasoning as deb.nix's `repos`). Each entry is a
  # repo base URL without the trailing architecture segment (apk appends
  # that itself), e.g. "https://dl-cdn.alpinelinux.org/alpine/v3.20/main".
  repos,

  architecture ? "x86_64",

  maintainer ? null,

  # Alpine's own package-release counter, appended to pkgver as "-rN"
  # (e.g. "1.0.0-r0") -- distinct from Arch's pkgrel on aur.nix in that
  # Alpine convention starts a package's first release at r0, not 1.
  pkgrel ? 0,
}:
let
  keyring = import ./keyring.pkg.nix { pkgs = alpinePkgs; };
in
mkTarget {
  pkgs = alpinePkgs;
  inherit lib;
  resolve = import ./resolver.nix { inherit lib architecture repos keyring; };
  inherit (import ./builder.nix { inherit lib collectDeps architecture maintainer pkgrel; })
    nativeDerivationFactory mkDerivation;
}
