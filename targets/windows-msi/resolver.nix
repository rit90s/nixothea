# See windows-exe's resolver for why buildPackages is required here.
{ lib }:
{ pkgs, deps }:
pkgs.buildPackages.writeShellApplication {
  name = "resolve-windows-msi";
  text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
}
