# nativeDerivationFactory: never actually called -- resolver.nix always
# emits an empty section, so there are never any dependencies to turn into
# a native representation. Exists to satisfy the target interface.
#
# mkDerivation: "root" builds one layered image (see docker-image.pkg.nix)
# out of every transitively-reachable node's own real build output, the
# same nested-node merge as appimage/snap/deb. "dependency" is a no-op,
# same reasoning as appimage.nix: a node used as a buildInput of something
# else is already a real input of that something's real build, hence
# already part of the Nix closure `dockerTools.buildLayeredImage` walks on
# its own -- there's nothing extra to bundle here.
{ lib, collectDeps, imageName, tag, mainProgram, entrypoint, cmd, env, workdir, exposedPorts, labels, user, extraContents, maxLayers, created }:
{
  nativeDerivationFactory = { pkgs, name, entry }:
    throw "nixothea docker target: does not support dependencies (got ${name})";

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        # "One layered image", the same idea as every other target's
        # nested-node merge: every transitively-reachable node's own real
        # build output, plus the root's own, listed as `contents` --
        # buildLayeredImage includes each one's full runtime closure on
        # its own (`includeStorePaths`, on by default), so this doesn't
        # need appimage.nix's manual closureInfo walk.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea docker target: ${realDrv.pname} has no bin/ directory -- set mainProgram or entrypoint explicitly"
          else
            let bins = builtins.attrNames (builtins.readDir "${realDrv}/bin");
            in
            if builtins.length bins == 1 then
              builtins.head bins
            else
              throw "nixothea docker target: ${realDrv.pname} ships ${toString (builtins.length bins)} binaries under bin/ -- set mainProgram or entrypoint explicitly";

        resolvedEntrypoint =
          if entrypoint != null then entrypoint
          else [ "${realDrv}/bin/${resolvedMainProgram}" ];

        resolvedImageName = if imageName != null then imageName else realDrv.pname;
        resolvedTag = if tag != null then tag else realDrv.version;
      in
      import ./docker-image.pkg.nix {
        inherit pkgs lib realDrv allPayloads extraContents;
        imageName = resolvedImageName;
        tag = resolvedTag;
        entrypoint = resolvedEntrypoint;
        inherit cmd env workdir exposedPorts labels user maxLayers created;
      }
    else
      throw "nixothea docker target: unknown role ${role}";
}
