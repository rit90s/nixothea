# A constructor: `nixothea.targets.windowsExe { }` returns a target that
# builds a real NSIS-based Windows installer (.exe). Unlike every other
# target, this one needs an actual cross-compiled Windows binary, not a
# repackaged Linux one -- so this target derives its own Windows cross
# pkgs (`pkgsCross.mingwW64`) from whatever native pkgs it's constructed
# with, itself, below, rather than requiring the caller to figure out and
# pass cross pkgs into `buildTarget`/`mkResolver` (see lib/mk-target.nix
# for why every target supplies its own pkgs this way). That's what lets
# this target sit in the very same `targets` attrset -- and the same
# `buildTarget`/`mkResolver` call -- as Linux-native targets (`deb`,
# `dnfFedora`, ...): each just builds against its own pkgs, regardless of
# what any other target in the same call needs.
#
# Dependencies work like the `nix` target's (see nix.nix): there's no
# Windows equivalent of apt/dnf to resolve arbitrary C library build
# dependencies against, but nixpkgs' own mingw cross package set already
# *is* a full, working answer -- `pkgsCross.mingwW64.zlib` is a real,
# correctly cross-compiled derivation. So dependencies are a transparent
# pass-through to `pkgs.<name>` (no lock file, no resolve step doing real
# work). DLL bundling happens for free: nixpkgs' own mingw setup hook
# already symlinks every actually-needed runtime DLL next to a binary's
# .exe in its own $out/bin/, transitively -- verified empirically (a
# 2-level dependency chain correctly propagated its DLL down to the final
# binary's own bin/, no extra effort needed here). So the whole payload is
# just `$out/bin/*` with symlinks dereferenced.
{ pkgs, mkTarget, collectDeps }:
let
  # The real pkgs this target builds against -- everything platform-
  # dependent (nsis, hostPlatform, ...) flows from this, not from
  # whatever native `pkgs` this constructor happened to receive.
  windowsPkgs = pkgs.pkgsCross.mingwW64;
  lib = windowsPkgs.lib;
in
{
  publisher ? null,

  # Which binary under the root derivation's $out/bin/ becomes the
  # installed app's entry point (Start Menu shortcut target). When null,
  # resolved the same way appimage's is: used directly if bin/ has
  # exactly one .exe, otherwise the build fails asking for this to be set
  # explicitly.
  mainProgram ? null,

  # Optional license text (or a path to a license file) shown as an
  # accept/decline page before install. A Nix path is used as-is; a string
  # is written out via writeText. NSIS's MUI_PAGE_LICENSE displays either
  # plain text or .rtf as given -- no format conversion needed here (unlike
  # windows-msi's license, which has to defend against a real msiexec
  # crash on non-RTF input; verified NSIS has no equivalent landmine).
  # When null (the default), no license page is added -- behavior is
  # unchanged from before this option existed.
  license ? null,

  # Raw NSIS script text spliced into the generated .nsi right after the
  # standard header directives (Unicode/OutFile/InstallDir/Name/
  # RequestExecutionLevel) and before the Page declarations (including the
  # license page above, if set). Lets a caller add their own !define/
  # !include, extra Page entries, custom Sections, Functions, icons,
  # version info, etc. without nixothea needing to model every NSIS
  # feature -- same trust model as any other caller-supplied builder
  # function in nixothea: invalid NSIS here just fails the caller's own
  # build. Empty by default (no-op).
  extraNsisScript ? "",
}:
mkTarget {
  pkgs = windowsPkgs;
  inherit lib;
  resolve = import ./resolver.nix { inherit lib; };
  inherit (import ./builder.nix {
    inherit lib collectDeps publisher mainProgram license extraNsisScript;
  }) nativeDerivationFactory mkDerivation;
}
