# Small, optional helpers factored out of duplicated logic that kept
# showing up verbatim across several of nixothea's own pre-implemented
# targets (see e.g. targets/appimage/builder.nix, targets/aur/builder.nix,
# targets/tarball/resolver.nix for real call sites) -- not part of the
# core mkTarget/mkResolver/buildTarget contract itself (see
# lib/mk-target.nix), and never required: a target implementation is
# always free to write its own `resolve`/`nativeDerivationFactory`/
# `mkDerivation` from scratch instead, the way most of nixothea's own
# targets with real dependency ecosystems (`deb`, `apk`, `dnf*`, ...) do.
#
# Exposed as `nixothea.lib.utils.targetImpl` (see flake.nix) -- like the
# rest of `nixothea.lib`, nothing here is bound to nixothea's own pinned
# nixpkgs; every piece takes whatever `lib`/`pkgs` its caller already has
# in scope as a plain argument, so it works against any nixpkgs pin.
{
  # { lib, targetName, realDrv, mainProgram, matchSuffix ? null, extraHelp ? "" }:
  #   <resolved name, or throws>
  # Auto-detects a target's "which binary under $out/bin/ is the entry
  # point" option. See the file itself for the full parameter reference.
  autoDetectMainProgram = import ./auto-detect-main-program.nix;

  # { lib, license }: [ "<spdx-or-short-name>" ... ]
  # Normalizes a `meta.license`-shaped value (string / nixpkgs license
  # attrset / list of either) into a flat list of plain strings. See the
  # file itself for the full parameter reference.
  licenseNames = import ./license-names.nix;

  # resolvers.empty/resolvers.passthrough : targetName: { pkgs, deps }: <derivation>
  # Two common `resolve` bodies for targets with no live registry to
  # resolve against. See the file itself for which is which.
  resolvers = import ./resolvers.nix;
}
