# nativeDerivationFactory: see extracted-dependency.pkg.nix.
#
# mkDerivation: "root" builds one combined .deb (see deb-package.pkg.nix).
# "dependency" is already a real input of whatever consumed it (buildInputs
# unwrapping already linked realDrv in for real) -- nothing further to do
# until the root folds its payload in.
{ lib, collectDeps, architecture, maintainer, section, priority }:
let
  multiarchTriplets = {
    amd64 = "x86_64-linux-gnu";
    arm64 = "aarch64-linux-gnu";
    armhf = "arm-linux-gnueabihf";
    i386 = "i386-linux-gnu";
  };

  # Standard glibc dynamic-linker install path per architecture -- what
  # the final .deb's own binaries get patched to (see deb-package.pkg.nix's
  # patchelf pass). Verified this isn't optional: a binary compiled by
  # Nix's stdenv has its ELF interpreter hardcoded to a Nix store glibc
  # path (`readelf -p .interp` on a built binary shows
  # `/nix/store/...-glibc-.../ld-linux-x86-64.so.2`), and confirmed with a
  # real bwrap sandbox with no /nix visible that this makes the built
  # .deb's binary fail to execute at all on a real target machine
  # (`execvp: No such file or directory`, not some fallback) --
  # completely independent of whether Depends: is satisfied.
  interpreters = {
    amd64 = "/lib64/ld-linux-x86-64.so.2";
    arm64 = "/lib/ld-linux-aarch64.so.1";
    armhf = "/lib/ld-linux-armhf.so.3";
    i386 = "/lib/ld-linux.so.2";
  };

  multiarchTriplet = multiarchTriplets.${architecture} or
    (throw "nixothea deb target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames multiarchTriplets)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea deb target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");
in
{
  nativeDerivationFactory = { pkgs, name, entry }:
    import ./extracted-dependency.pkg.nix { inherit pkgs lib entry multiarchTriplet; };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        allDebPackages = builtins.attrValues (builtins.listToAttrs
          (map (p: { inherit (p) name; value = p; })
            (lib.concatMap (d: d.debPackages) (dependencyDeps ++ collected.dependencies))));

        # -dev packages (headers, static libs, unversioned .so symlinks for
        # linking) are needed to build against, never at runtime -- a real
        # installed package shouldn't pull them in.
        runtimeDebPackages = lib.filter (p: p.section != "libdevel") allDebPackages;

        # "One combined package", same as aur: every transitively-reachable
        # node's own real build output is folded into the same payload
        # tree as the root's, not split into separate interdependent .debs.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;
      in
      import ./deb-package.pkg.nix {
        inherit pkgs lib realDrv allPayloads runtimeDebPackages maintainer section priority architecture targetInterpreter;
        description = args.meta.description or "";
      }
    else
      throw "nixothea deb target: unknown role ${role}";
}
