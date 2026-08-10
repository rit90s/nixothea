# No live registry to resolve against -- see the header comment in
# default.nix for why this target has no declared-dependency system at
# all. Always emits an empty section regardless of `deps`.
{ lib }:
{ pkgs, deps }:
pkgs.writeShellApplication {
  name = "resolve-flatpak";
  text = "echo '{}'";
}
