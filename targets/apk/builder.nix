# nativeDerivationFactory: see extracted-dependency.pkg.nix.
#
# mkDerivation: "root" builds one combined .apk (see apk-package.pkg.nix).
# "dependency" is already a real input of whatever consumed it (buildInputs
# unwrapping already linked realDrv in for real) -- nothing further to do
# until the root folds its payload in.
{ lib, collectDeps, architecture, maintainer, pkgrel }:
let
  # Alpine's real, standard musl dynamic-linker install path per
  # architecture -- what the final .apk's own binaries get patched to
  # (see apk-package.pkg.nix's patchelf pass). Same reasoning as deb.nix's
  # own `interpreters` map: a binary compiled by Nix's stdenv has its ELF
  # interpreter hardcoded to a Nix store path, which won't resolve on a
  # real Alpine machine.
  interpreters = {
    x86_64 = "/lib/ld-musl-x86_64.so.1";
    aarch64 = "/lib/ld-musl-aarch64.so.1";
  };

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea apk target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");
in
{
  nativeDerivationFactory = { pkgs, name, entry }:
    import ./extracted-dependency.pkg.nix { inherit pkgs lib entry; };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      assert lib.assertMsg pkgs.stdenv.hostPlatform.isMusl
        "nixothea apk target: pkgs passed to buildTarget must be a musl pkgs (e.g. pkgsMusl), got libc '${pkgs.stdenv.hostPlatform.libc}' -- Alpine is musl-based, and a glibc binary can't simply have its interpreter retargeted the way deb/rpm's glibc-to-glibc retarget works";
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        allApkPackages = builtins.attrValues (builtins.listToAttrs
          (map (p: { inherit (p) name; value = p; })
            (lib.concatMap (d: d.apkPackages) (dependencyDeps ++ collected.dependencies))));

        # -dev packages (headers, static libs, unversioned .so symlinks for
        # linking) are needed to build against, never at runtime -- Alpine's
        # own real dependency graphs never pull these in transitively, so
        # the only way one ends up here is a caller naming one directly as
        # their logical dependency's real name. pkgconf is excluded for the
        # same reason but one step removed: real -dev packages routinely
        # `depend = pkgconf` themselves (so a real human installing e.g.
        # zlib-dev gets working `pkg-config --libs zlib`), which means it
        # rides along in the very same `apk fetch -R` closure as a -dev
        # package -- verified against a real fetch of zlib-dev, which pulls
        # in pkgconf this way. Same class of imprecision as deb.nix's own
        # EXCLUDE_RE (a curated list, not a full graph-aware prune of
        # what's only reachable through an already-excluded -dev node).
        excludeNames = [ "pkgconf" ];
        runtimeApkPackages = lib.filter
          (p: !(lib.hasSuffix "-dev" p.name || lib.hasSuffix "-static" p.name || lib.elem p.name excludeNames))
          allApkPackages;

        # "One combined package", same as deb: every transitively-reachable
        # node's own real build output is folded into the same payload
        # tree as the root's, not split into separate interdependent .apks.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;
      in
      import ./apk-package.pkg.nix {
        inherit pkgs lib realDrv allPayloads runtimeApkPackages maintainer pkgrel architecture targetInterpreter;
        description = args.meta.description or "";
        license = args.meta.license or null;
      }
    else
      throw "nixothea apk target: unknown role ${role}";
}
