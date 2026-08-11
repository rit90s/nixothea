# A portable tarball is fully self-contained (no host package manager
# involved), so this target doesn't participate in dependency resolution --
# always emits an empty section, same reasoning as appimage/docker.
{ lib }:
{ pkgs, deps }:
pkgs.writeShellApplication {
  name = "resolve-tarball";
  text = "echo '{}'";
}
