# A constructor: `nixothea.targets.windowsMsi { upgradeCode = "..."; }`
# returns a target that builds a real WiX-format .msi via `wixl` (from
# msitools) -- WiX itself isn't packaged for Linux, but msitools is a
# from-scratch reimplementation of a WiX-compatible compiler that runs
# natively on Linux, no Wine needed to *build* the .msi (only to test
# running it, which this target's development used `wine`'s own
# `msiexec`/`wine` for). Same cross-compilation requirement as
# windows-exe -- see that target's header comment for why this target
# derives its own Windows cross pkgs itself (rather than requiring the
# caller to pass one into `buildTarget`/`mkResolver`), why dependencies
# are a transparent pass-through to `pkgs.<name>`, and why DLL bundling
# needs no extra work (nixpkgs' own mingw setup hook already symlinks
# every actually-needed DLL into a binary's own $out/bin/, transitively).
{ pkgs, mkTarget, collectDeps }:
let
  # The real pkgs this target builds against -- see windows-exe's header
  # comment.
  windowsPkgs = pkgs.pkgsCross.mingwW64;
  lib = windowsPkgs.lib;
in
{
  # Mandatory, no default -- same reasoning as `repos`/`releasever` on the
  # dnf-based targets: MSI's upgrade-detection model keys off this GUID
  # staying constant across every version of a given app forever, so
  # silently generating one would be exactly the kind of implicit,
  # hard-to-undo choice a caller should make explicitly (get it wrong and
  # MSI's upgrade/uninstall behavior silently breaks for existing
  # installs). `productCode` (which, unlike UpgradeCode, *should* change
  # per version under real MSI semantics) is deterministically derived
  # from this plus the package version instead of also being manual or
  # left to wixl's non-reproducible "*" auto-generation -- nothing
  # arbitrary is being decided on the caller's behalf, it's a mechanical
  # function of information the caller already fully controls.
  upgradeCode,

  publisher ? null,
  mainProgram ? null,

  # Optional license text (or a path to a license file) shown as an
  # accept/decline page before install, via wixl's bundled WixUI_Minimal
  # extension (verified this ships as a real usable extension, not just a
  # WiX-on-Windows-only feature -- `wixl --ext ui` pulls in the same
  # dialog set real WiX ships). Unlike windows-exe's license (which NSIS
  # displays as either plain text or .rtf, no conversion needed), MSI's
  # ScrollableText control genuinely requires RTF -- verified empirically
  # that feeding it plain text crashes msiexec outright (invalid RTF
  # parsing, not a graceful fallback). So a string that doesn't already
  # look like RTF (start with "{\rtf") is auto-wrapped into a minimal
  # valid RTF document; a string that's already RTF, or a path to a .rtf
  # file, is used as-is. When null (the default), no license page is
  # added -- behavior unchanged from before this option existed,
  # including for silent (/qn) installs either way, since the license
  # dialog only exists in the interactive UI sequence.
  license ? null,

  # Raw WiX XML spliced in just before </Product>, for anything not
  # covered above (extra <Feature>/<Property>/<UI>/<WixVariable> etc.) --
  # same escape-hatch/trust model as windows-exe's extraNsisScript. Empty
  # by default (no-op).
  extraWxsXml ? "",
}:
mkTarget {
  pkgs = windowsPkgs;
  inherit lib;
  resolve = import ./resolver.nix { inherit lib; };
  inherit (import ./builder.nix {
    inherit lib collectDeps upgradeCode publisher mainProgram license extraWxsXml;
  }) nativeDerivationFactory mkDerivation;
}
