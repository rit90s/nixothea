# No live registry to resolve against -- see aur's resolver for the same
# reasoning (pacman/brew both resolve dependencies themselves, later, at
# install time).
{ lib }:
{ pkgs, deps }:
pkgs.writeShellApplication {
  name = "resolve-homebrew";
  text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
}
