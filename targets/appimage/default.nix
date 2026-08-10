# A constructor: `nixothea.targets.appimage { icon = ...; }` returns a
# target. AppImages are fully self-contained (no host package manager
# involved), so this target doesn't participate in dependency resolution --
# `resolve` always emits an empty section, and the root build bundles
# whatever runtime closure it actually needs directly.
{ pkgs, mkTarget }:
let
  lib = pkgs.lib;
  runtime = import ./runtime.pkg.nix { inherit pkgs; };
in
{
  # Path to the icon shown in app launchers. The AppImage runtime itself
  # doesn't care -- it never parses the .desktop file, just execs AppRun --
  # so this only affects desktop integration. When null, the .desktop
  # file's Icon= is omitted instead of failing the build.
  icon ? null,

  # freedesktop.org Categories= for the .desktop file.
  categories ? [ "Utility" ],

  # squashfs compression algorithm for the payload. "gzip" builds fastest;
  # "xz"/"zstd" produce smaller AppImages at the cost of build time.
  compression ? "gzip",

  # Which binary under the root derivation's $out/bin/ the generated AppRun
  # execs. When null, resolved from $out/bin/: used directly if there's
  # exactly one entry, otherwise the build fails asking for mainProgram to
  # be set explicitly.
  mainProgram ? null,

  # Not yet implemented: embedding zsync update info requires patching an
  # ELF section into the runtime stub, which needs verifying against the
  # exact section layout the real appimagetool produces.
  updateInformation ? null,
}:
mkTarget {
  inherit lib;
  resolve = import ./resolver.nix { inherit lib; };
  inherit (import ./builder.nix {
    inherit lib runtime icon categories compression mainProgram updateInformation;
  }) nativeDerivationFactory mkDerivation;
}
