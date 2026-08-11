# nativeDerivationFactory: never actually called -- resolver.nix always
# emits an empty section, so there are never any dependencies to turn into
# pkgs.<name> values. Exists to satisfy the target interface.
{ lib, compression, mainProgram }:
{
  nativeDerivationFactory = { pkgs, name, entry }:
    throw "nixothea tarball target: does not support dependencies (got ${name})";

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      # Same reasoning as appimage.nix: a node used as a buildInput of
      # something else is already a real input of that something's real
      # build, hence already part of the Nix closure the root build below
      # bundles in full regardless of how deeply nested it was.
      realDrv
    else if role == "root" then
      let
        closureInfo = pkgs.closureInfo { rootPaths = [ realDrv ]; };

        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea tarball target: ${realDrv.pname} has no bin/ directory -- set mainProgram explicitly"
          else
            let bins = builtins.attrNames (builtins.readDir "${realDrv}/bin");
            in
            if builtins.length bins == 1 then
              builtins.head bins
            else
              throw "nixothea tarball target: ${realDrv.pname} ships ${toString (builtins.length bins)} binaries under bin/ -- set mainProgram explicitly";
      in
      assert lib.assertMsg (resolvedMainProgram != "nix")
        "nixothea tarball target: mainProgram can't be \"nix\" -- collides with the bundled closure's own nix/ directory at the top level of the extracted tarball";
      import ./tarball-package.pkg.nix {
        inherit pkgs lib realDrv closureInfo resolvedMainProgram compression;
      }
    else
      throw "nixothea tarball target: unknown role ${role}";
}
