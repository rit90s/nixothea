# nativeDerivationFactory: see extracted-dependency.pkg.nix.
#
# mkDerivation: "root" builds one combined .rpm (see rpm-package.pkg.nix),
# same nested-node merge as aur/deb. "dependency" is already a real input
# of whatever consumed it (buildInputs unwrapping already linked realDrv
# in for real) -- nothing further to do until the root folds its payload
# in.
{ lib, collectDeps, architecture, vendor, license, group }:
let
  # Nix's bintools-wrapper setup hook adds `-L$dep/lib64` (skipped if it's a
  # symlink!) and `-L$dep/lib` (symlink is fine, just needs to glob-match
  # lib*) -- so the convenience symlink below always has to be named `lib`,
  # never `lib64`, regardless of which real directory it points at.
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
  # path (`readelf -p .interp` on a built binary shows
  # `/nix/store/...-glibc-.../ld-linux-x86-64.so.2`), and confirmed with a
  # real bwrap sandbox with no /nix visible that this makes the built
  # .rpm's binary fail to execute at all on a real target machine
  # (`execvp: No such file or directory`, not some fallback) --
  # completely independent of whether Requires: is satisfied.
  interpreters = {
    x86_64 = "/lib64/ld-linux-x86-64.so.2";
    aarch64 = "/lib/ld-linux-aarch64.so.1";
    ppc64le = "/lib64/ld64.so.2";
    s390x = "/lib/ld64.so.1";
    i686 = "/lib/ld-linux.so.2";
    armv7hl = "/lib/ld-linux-armhf.so.3";
  };

  libDir = archLibDirs.${architecture} or
    (throw "nixothea dnfFedora target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames archLibDirs)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea dnfFedora target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");
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

        # -devel packages (headers, static libs, unversioned .so symlinks
        # for linking) are needed to build against, never at runtime -- a
        # real installed package shouldn't pull them in.
        runtimeRpmPackages = lib.filter (p: p.kind != "devel") allRpmPackages;

        # "One combined package", same as aur/deb: every
        # transitively-reachable node's own real build output is folded
        # into the same payload tree as the root's, not split into
        # separate interdependent .rpms.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        description = args.meta.description or "";
      in
      import ./rpm-package.pkg.nix {
        inherit pkgs lib realDrv allPayloads runtimeRpmPackages description license group architecture vendor targetInterpreter;
      }
    else
      throw "nixothea dnfFedora target: unknown role ${role}";
}
