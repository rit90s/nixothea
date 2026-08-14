# A constructor: `nixothea.targets.snap { }` returns a target that
# produces a real, pre-built Snap package tree (a `snap/snapcraft.yaml`
# plus its own local `payload/` directory) -- unlike this target's first
# version, this one does a real Nix-level compile, the same as
# `deb`/`dnf-*`/`windowsExe`/`windowsMsi`, not the `aur`/`homebrew`/
# `flatpak` "recipe only, the real compile happens client-side" style.
# `snapcraft --destructive-mode` (or a real managed build) still has to
# run to actually pack the `.snap`, but its only job is copying
# already-built files into place (`plugin: dump`) -- no compiling, no
# live `apt` fetch, at `snapcraft`-build time at all.
#
# Real background this design relies on (verified empirically against a
# real Ubuntu 24.04 qemu/KVM VM, no `/nix` visible, real `snapd`): a
# strict-confinement snap's app process runs inside a mount namespace
# where the *base* snap (e.g. `core24` -- a minimal real Ubuntu userspace)
# is mounted at the standard absolute FHS paths (a real
# `/lib64/ld-linux-x86-64.so.2`, a real
# `/usr/lib/x86_64-linux-gnu/libc.so.6`, ...), with `$SNAP` layered on
# top. A normally-linked Ubuntu binary's hardcoded ELF interpreter just
# resolves correctly against that -- no patchelf needed for *that* part,
# unlike `appimage.nix` (which can't assume any particular target
# filesystem exists at all) but very much like `deb` (which relies on
# the target Debian machine's own real glibc). The one thing genuinely
# different from `deb`: a Nix-built binary's interpreter is a
# `/nix/store/...` path, which the sandbox's mount namespace simply
# doesn't contain (ENOENT, not an AppArmor denial) -- so it still needs
# patchelf-ing to the base's real, known interpreter path, the same idea
# as `deb`'s own `interpreters` map, just pointed at the base snap's
# Ubuntu release instead of an arbitrary caller-supplied `repos`.
#
# The other real, load-bearing difference from `deb`: a `.deb`'s
# runtime dependencies are satisfied by `Depends:` -- the *target
# machine's own* `apt` installs them separately, from the same repo, at
# package-install time. A strict-confinement snap has no equivalent:
# nothing outside `$SNAP`/the base/a connected content-interface snap is
# visible to it at all, so there is no later "apt install" step to lean
# on. Every runtime library a declared dependency provides has to be
# bundled directly into this snap's own payload -- not just declared and
# trusted the way `deb`'s `Depends:` line can get away with. Verified
# empirically end to end (real `stage-packages`-based predecessor test,
# then this real-bundling redesign): `snapd` sets a default
# `LD_LIBRARY_PATH` for strict-confinement apps covering
# `$SNAP/usr/lib/<triplet>`, so a bundled `.so` at the normal Debian/
# Ubuntu path is found automatically -- no explicit RPATH needed on our
# own built binaries either, just the interpreter fix above.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  # Which real Ubuntu release a given Snap base corresponds to -- this is
  # inherent to what the base *means* (Canonical ties each one to a
  # specific Ubuntu release), not a caller choice the way `deb`'s `repos`
  # is for arbitrary Debian derivatives.
  baseSuites = {
    core24 = "noble";
    core22 = "jammy";
    core20 = "focal";
    core18 = "bionic";
  };
in
{
  base ? "core24",
  confinement ? "strict",
  grade ? "stable",
  architecture ? "amd64",
}:
let
  suite = baseSuites.${base} or
    (throw "nixothea snap target: unsupported base '${base}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames baseSuites)})");

  # Ubuntu's primary archive only carries amd64/i386 -- other
  # architectures are hosted on the separate, real "ports" archive. A
  # real Ubuntu infrastructure split, not a nixothea-specific choice.
  archiveHost =
    if builtins.elem architecture [ "amd64" "i386" ]
    then "http://archive.ubuntu.com/ubuntu"
    else "http://ports.ubuntu.com/ubuntu-ports";

  repoSuites = [ suite "${suite}-updates" "${suite}-security" ];
  components = [ "main" "universe" "restricted" "multiverse" ];

  sourcesList = pkgs.writeText "sources.list" (lib.concatMapStringsSep "\n"
    (s: "deb ${archiveHost} ${s} ${lib.concatStringsSep " " components}")
    repoSuites);

  keyring = import ./keyring.pkg.nix { inherit pkgs; };
in
mkTarget {
  inherit pkgs lib;
  resolve = import ./resolver.nix { inherit lib architecture sourcesList keyring; };
  inherit (import ./builder.nix { inherit lib collectDeps architecture base confinement grade; })
    nativeDerivationFactory mkDerivation;
}
