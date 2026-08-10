# A constructor: `nixothea.targets.flatpak { appId = "..."; }` returns a
# target that produces a Flatpak build manifest (a JSON file) -- like the
# aur/homebrew targets, nixothea never compiles the real software itself,
# it only generates the recipe. The real compile happens later, for real,
# when `flatpak-builder` runs the manifest's modules on a real machine
# (typically a publisher's build machine producing a distributable
# .flatpak bundle, more like how most people consume Homebrew *bottles*
# than how AUR users routinely compile from source themselves -- but the
# mechanism nixothea produces is the same either way).
#
# Structurally different from aur/homebrew in one real way: apt/dnf/
# pacman/brew all let a package declare a dependency *by name* and get a
# real fetchable package back. Flatpak has no such concept -- there is no
# "install this named library" at manifest-build time. Every dependency
# not already covered by the chosen `runtime` has to be its own source-
# building module, right there in the same manifest, with its own real
# URL and hash. So this target -- like appimage's, for the same
# underlying reason -- has no declared-dependency system at all
# (`resolve` always emits an empty section, `nativeDerivationFactory` is
# never called): nixothea's *existing* nested-node mechanism already does
# the job, since a nested `pkgs.mkDerivation` used as a buildInput already
# carries its own buildPhase/installPhase, which is exactly what a
# Flatpak module is. Each transitively-reachable node becomes its own
# `modules[]` entry, built in collectDeps' order (nested nodes first, root
# last -- not a real topological sort, same caveat as every other
# target's nested-node merge).
#
# The whole manifest is built as a plain Nix attrset and serialized via
# builtins.toJSON -- unlike aur.nix's PKGBUILD (bash) or homebrew.nix's
# Formula (Ruby), a Flatpak manifest already *is* JSON, so there's no
# hand-rolled shell/Ruby string escaping to get right here; toJSON handles
# it correctly by construction.
#
# Known limitations, kept out of scope for this pass:
#   - no AppStream metadata (.metainfo.xml) generation -- meta.description/
#     meta.license (used by aur/homebrew) have no natural home in the core
#     build manifest itself, that's a separate mechanism entirely;
#   - `finish-args` (sandbox permissions -- network, filesystem, graphics
#     sockets, ...) defaults to empty (most restrictive), not inferred --
#     this is a real security-relevant decision only the caller can make
#     correctly, deliberately not defaulted to anything permissive;
#   - no runtime auto-detection (e.g. picking org.gnome.Platform for a GTK
#     app) -- `runtime`/`sdk` default to the generic freedesktop ones;
#   - `buildsystem` is always "simple" (raw build-commands) -- no
#     autotools/cmake/meson preset support, same reasoning as aur/
#     homebrew's raw shell splicing.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;
in
{
  # Reverse-DNS app identifier (e.g. "com.example.MyApp") -- mandatory, no
  # default. Deeply consequential and hard to change later (baked into
  # D-Bus names and the app's own per-user data directory forever), same
  # reasoning as `upgradeCode` on the MSI target being mandatory.
  appId,

  runtime ? "org.freedesktop.Platform",
  runtimeVersion ? "24.08",
  sdk ? "org.freedesktop.Sdk",

  # Raw Flatpak sandbox-permission strings (e.g. [ "--share=network"
  # "--socket=wayland" ]) -- empty by default (most restrictive), not
  # inferred from anything. See the header comment.
  finishArgs ? [ ],

  # The manifest's `command` field -- mandatory, unlike appimage.nix's
  # auto-detected mainProgram. Auto-detection there works by checking
  # what's actually under "${realDrv}/bin" -- but interpolating a
  # derivation into a Nix string forces Nix to actually realize its
  # build, and for appimage.nix (which always does a real Nix-level
  # compile regardless) that's free. This target, like aur.nix/
  # homebrew.nix, deliberately *never* does a real Nix-level compile --
  # the whole point is that the real build happens later, client-side,
  # via flatpak-builder. A real-world buildPhase/installPhase here is
  # written for that later, different environment (real fetched source,
  # real flatpak-builder sandbox) and has no reason to also succeed as a
  # standalone Nix build against nothing (dontUnpack = true, no source
  # fetched) -- so auto-detecting via a forced real build would silently
  # break real usage. Verified this the hard way: a package definition
  # with a genuine "./configure && make" buildPhase (needing real
  # upstream source only flatpak-builder would ever fetch) failed at the
  # Nix level with "./configure: No such file or directory" the moment
  # mainProgram auto-detection tried to peek into $out/bin.
  mainProgram,
}:
mkTarget {
  inherit lib;
  resolve = import ./resolver.nix { inherit lib; };
  inherit (import ./builder.nix {
    inherit lib collectDeps appId runtime runtimeVersion sdk finishArgs mainProgram;
  }) nativeDerivationFactory mkDerivation;
}
