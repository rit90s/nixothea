# A constructor: `nixothea.targets.tarball { }` returns a target that
# produces a portable, relocatable `.tar.gz` (or `.tar.xz`/`.tar.zst`) --
# the package's full Nix runtime closure bundled under one top-level
# directory, alongside a generated launcher script, extractable and
# runnable on any machine with no real `/nix/store` and no host package
# manager involved. The launcher is named after `mainProgram` itself, not
# e.g. "run.sh" -- so `tar xf foo-1.0.tar.gz && cd foo-1.0 && ./foo` looks
# and runs like invoking the real binary directly, even though it's
# actually this wrapper. Same self-contained reasoning as appimage.nix
# (`resolve` always emits an empty section, `nativeDerivationFactory` is
# never called) and the same relocation fix (the launcher execs the
# bundled dynamic linker directly with an explicit `--library-path`,
# instead of relying on the kernel's automatic, absolute-path `PT_INTERP`
# dispatch) -- just without appimage.nix's squashfs-plus-runtime-stub
# packaging, or any desktop integration (no `.desktop` file/icon, since
# there's no launcher menu to integrate with).
{ pkgs, mkTarget }:
let
  lib = pkgs.lib;
in
{
  # Which binary under the root derivation's $out/bin/ the launcher execs
  # -- also the launcher's own filename at the top level of the extracted
  # tarball. When null, resolved from $out/bin/: used directly if there's
  # exactly one entry, otherwise the build fails asking for mainProgram to
  # be set explicitly. Can't be "nix" -- collides with the bundled
  # closure's own nix/ directory.
  mainProgram ? null,

  # tar compression. "none" produces a plain uncompressed .tar; "gzip"
  # is the most broadly compatible compressed choice; "xz"/"zstd" produce
  # smaller archives at the cost of build time (and, for "zstd", requiring
  # a newer `tar` on the extracting machine to auto-detect it without
  # `--zstd` being passed explicitly).
  compression ? "gzip",
}:
mkTarget {
  inherit pkgs lib;
  resolve = import ./resolver.nix { inherit lib; };
  inherit (import ./builder.nix {
    inherit lib compression mainProgram;
  }) nativeDerivationFactory mkDerivation;
}
