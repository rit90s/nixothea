# Docker images are fully self-contained -- there's no host package manager
# to declare a runtime dependency to, `dockerTools.buildLayeredImage` walks
# the real Nix closure of whatever's listed in `contents` itself -- so this
# target doesn't participate in dependency resolution, same reasoning as
# appimage's resolver.nix. Always emits an empty section, regardless of
# `deps`.
{ lib }:
{ pkgs, deps }:
pkgs.writeShellApplication {
  name = "resolve-docker";
  text = "echo '{}'";
}
