# Aggregates every pre-implemented target into one attrset, ready to
# instantiate, e.g. `nixothea.targets.${system}.appimage { icon = ./icon.png; }`.
# Each entry is either a flat `<name>.nix` file (small targets, e.g. `nix`)
# or a `<name>/default.nix` (targets big enough to split across
# resolver.nix/builder.nix/default.nix, and sometimes a *.pkg.nix for a
# sizeable pinned fetched artifact -- see e.g. targets/deb/) -- `import`
# resolves a directory to its own default.nix transparently either way, so
# this file doesn't need to know or care which shape a given target uses.
{ pkgs, mkTarget, collectDeps }:
{
  nix = import ./nix.nix { inherit pkgs mkTarget; };
  appimage = import ./appimage { inherit pkgs mkTarget; };
  aur = import ./aur { inherit pkgs mkTarget collectDeps; };
  homebrew = import ./homebrew { inherit pkgs mkTarget collectDeps; };
  flatpak = import ./flatpak { inherit pkgs mkTarget collectDeps; };
  snap = import ./snap { inherit pkgs mkTarget collectDeps; };
  deb = import ./deb { inherit pkgs mkTarget collectDeps; };
  dnfFedora = import ./dnf-fedora { inherit pkgs mkTarget collectDeps; };
  dnfRhel = import ./dnf-rhel { inherit pkgs mkTarget collectDeps; };
  dnfOpensuse = import ./dnf-opensuse { inherit pkgs mkTarget collectDeps; };
  # windowsExe/windowsMsi are constructed with the same native `pkgs` as
  # every other target above (their own construction-time `pkgs` is only
  # ever used for the platform-agnostic `.lib`), but actually *using* them
  # needs a `buildTarget`/`mkResolver` call with
  # `pkgs = nixpkgs.legacyPackages.${system}.pkgsCross.mingwW64` (or
  # another Windows cross pkgs) passed in explicitly -- these targets need
  # a real cross-compiled Windows binary, not a repackaged Linux one, so
  # they can't share a single buildTarget call with deb/dnfFedora/etc. the
  # way those share with each other. See targets/windows-exe/default.nix's
  # header comment.
  windowsExe = import ./windows-exe { inherit pkgs mkTarget collectDeps; };
  windowsMsi = import ./windows-msi { inherit pkgs mkTarget collectDeps; };
}
