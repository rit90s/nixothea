# nativeDerivationFactory: never actually called -- resolver.nix always
# emits an empty section, so there are never any dependencies to turn into
# pkgs.<name> values. Exists to satisfy the target interface.
{ lib, runtime, icon, categories, compression, mainProgram, updateInformation }:
{
  nativeDerivationFactory = { pkgs, name, entry }:
    throw "nixothea appimage target: does not support dependencies (got ${name})";

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      # A node used as a buildInput of something else is already a real
      # dependency of that something's real build (see
      # wrap-mk-derivation.nix -- realDrv is unwrapped into the real
      # compile for real linking), which means it's already part of that
      # build's Nix closure. Since the root build below bundles its *full*
      # closure regardless, there's nothing extra to do here.
      realDrv
    else if role == "root" then
      let
        closureInfo = pkgs.closureInfo { rootPaths = [ realDrv ]; };

        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea appimage target: ${realDrv.pname} has no bin/ directory -- set mainProgram explicitly"
          else
            let bins = builtins.attrNames (builtins.readDir "${realDrv}/bin");
            in
            if builtins.length bins == 1 then
              builtins.head bins
            else
              throw "nixothea appimage target: ${realDrv.pname} ships ${toString (builtins.length bins)} binaries under bin/ -- set mainProgram explicitly";

        iconExt = lib.last (lib.splitString "." (baseNameOf (toString icon)));

        desktopFile = pkgs.writeText "${realDrv.pname}.desktop" ''
          [Desktop Entry]
          Type=Application
          Name=${realDrv.pname}
          Exec=AppRun
          ${lib.optionalString (icon != null) "Icon=${realDrv.pname}"}
          Categories=${lib.concatStringsSep ";" categories};
        '';
      in
      assert lib.assertMsg (updateInformation == null)
        "nixothea appimage target: updateInformation is not yet implemented";
      import ./appimage-package.pkg.nix {
        inherit pkgs lib runtime realDrv closureInfo resolvedMainProgram icon iconExt desktopFile compression;
      }
    else
      throw "nixothea appimage target: unknown role ${role}";
}
