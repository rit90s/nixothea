# Nothing to resolve against a live registry -- dependencies are a
# transparent pass-through to pkgs.<name> (see builder.nix's
# nativeDerivationFactory). `pkgs.buildPackages.*`, not `pkgs.*`: this
# script needs to actually run on the build machine via `nix run`, but
# `pkgs` here is buildTarget/mkResolver's own (Windows cross) pkgs --
# plain `pkgs.writeShellApplication` would try to build the wrapper itself
# *for Windows* (verified empirically: it fails outright, evaluating a
# derivation tagged with an unbuildable "system"), since Nix's usual
# automatic build/host splicing only kicks in for buildInputs/
# nativeBuildInputs lists, not a directly-called package function like
# this.
{ lib }:
{ pkgs, deps }:
pkgs.buildPackages.writeShellApplication {
  name = "resolve-windows-exe";
  text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
}
