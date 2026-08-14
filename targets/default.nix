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
  tarball = import ./tarball { inherit pkgs mkTarget; };
  docker = import ./docker { inherit pkgs mkTarget collectDeps; };
  aur = import ./aur { inherit pkgs mkTarget collectDeps; };
  homebrew = import ./homebrew { inherit pkgs mkTarget collectDeps; };
  flatpak = import ./flatpak { inherit pkgs mkTarget collectDeps; };
  snap = import ./snap { inherit pkgs mkTarget collectDeps; };
  deb = import ./deb { inherit pkgs mkTarget collectDeps; };
  dnfFedora = import ./dnf-fedora { inherit pkgs mkTarget collectDeps; };
  dnfRhel = import ./dnf-rhel { inherit pkgs mkTarget collectDeps; };
  dnfOpensuse = import ./dnf-opensuse { inherit pkgs mkTarget collectDeps; };
  apk = import ./apk { inherit pkgs mkTarget collectDeps; };
  # windowsExe/windowsMsi are constructed with the same native `pkgs` as
  # every other target above, same as apk -- each derives whatever pkgs
  # it actually needs (a Windows cross pkgs, a musl pkgs) from this native
  # one itself (see targets/windows-exe/default.nix, targets/apk/default.nix,
  # and lib/mk-target.nix for why), so unlike before, these can be mixed
  # freely with Linux-native targets in the very same buildTarget/
  # mkResolver call -- no separate call with different pkgs needed.
  windowsExe = import ./windows-exe { inherit pkgs mkTarget collectDeps; };
  windowsMsi = import ./windows-msi { inherit pkgs mkTarget collectDeps; };
}
