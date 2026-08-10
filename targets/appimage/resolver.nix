# AppImages are fully self-contained (no host package manager involved),
# so this target doesn't participate in dependency resolution -- always
# emits an empty section, regardless of `deps`.
{ lib }:
{ pkgs, deps }:
pkgs.writeShellApplication {
  name = "resolve-appimage";
  text = "echo '{}'";
}
