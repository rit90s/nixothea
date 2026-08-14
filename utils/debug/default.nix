# Debugging aids for someone *consuming* nixothea to package their own
# app -- as opposed to utils/targetImpl, which is for someone
# *implementing* a new target. Exposed as `nixothea.lib.utils.debug` (see
# flake.nix). Like the rest of `nixothea.lib`, nothing here is bound to
# nixothea's own pinned nixpkgs.
{
  # { targets, lockFile, definition ? ... }: { <targetName> = <devShell>; ... }
  # A `nix develop .#<targetName>`-able shell per target, built against
  # that target's own real `pkgs` with its real resolved dependencies
  # available. See the file itself for the full parameter reference.
  mkDevShells = import ./mk-dev-shells.nix;
}
