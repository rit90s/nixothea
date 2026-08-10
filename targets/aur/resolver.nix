# No live registry to resolve against here (unlike a real repo target,
# e.g. deb/rpm) -- pacman/AUR resolve dependencies themselves, later, at
# install time -- so this just echoes the declared dependency spec back
# as the lock section, unchanged.
{ lib }:
{ pkgs, deps }:
pkgs.writeShellApplication {
  name = "resolve-aur";
  text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
}
