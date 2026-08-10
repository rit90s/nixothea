# nativeDerivationFactory: see extracted-dependency.pkg.nix.
#
# mkDerivation: "root" builds one combined .rpm (see rpm-package.pkg.nix).
# "dependency" is already a real input of whatever consumed it.
{ lib, collectDeps, architecture, vendor, license, group }:
let
  # Same as dnf-fedora: bintools-wrapper's setup hook skips `$dep/lib64`
  # when it's a symlink, so the convenience symlink always has to be
  # named `lib`.
  archLibDirs = {
    x86_64 = "lib64";
    aarch64 = "lib64";
    ppc64le = "lib64";
    s390x = "lib64";
    i686 = "lib";
    armv7hl = "lib";
  };

  # Standard glibc dynamic-linker install path per architecture -- what
  # the final .rpm's own binaries get patched to (see rpm-package.pkg.nix's
  # patchelf pass). Verified this isn't optional: a binary compiled by
  # Nix's stdenv has its ELF interpreter hardcoded to a Nix store glibc
  # path, and confirmed with a real bwrap sandbox with no /nix visible
  # that this makes the built .rpm's binary fail to execute at all on a
  # real target machine (`execvp: No such file or directory`, not some
  # fallback) -- completely independent of whether Requires: is
  # satisfied.
  interpreters = {
    x86_64 = "/lib64/ld-linux-x86-64.so.2";
    aarch64 = "/lib/ld-linux-aarch64.so.1";
    ppc64le = "/lib64/ld64.so.2";
    s390x = "/lib/ld64.so.1";
    i686 = "/lib/ld-linux.so.2";
    armv7hl = "/lib/ld-linux-armhf.so.3";
  };

  libDir = archLibDirs.${architecture} or
    (throw "nixothea dnfRhel target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames archLibDirs)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea dnfRhel target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");
in
{
  nativeDerivationFactory = { pkgs, name, entry }:
    import ./extracted-dependency.pkg.nix { inherit pkgs lib entry libDir; };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        allRpmPackages = builtins.attrValues (builtins.listToAttrs
          (map (p: { inherit (p) name; value = p; })
            (lib.concatMap (d: d.rpmPackages) (dependencyDeps ++ collected.dependencies))));

        runtimeRpmPackages = lib.filter (p: p.kind != "devel") allRpmPackages;

        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        description = args.meta.description or "";
      in
      import ./rpm-package.pkg.nix {
        inherit pkgs lib realDrv allPayloads runtimeRpmPackages description license group architecture vendor targetInterpreter;
      }
    else
      throw "nixothea dnfRhel target: unknown role ${role}";
}
