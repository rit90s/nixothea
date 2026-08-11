# Builds the real layered OCI/Docker image tarball via
# `dockerTools.buildLayeredImage`, from `allPayloads` (every transitively-
# reachable node's own real build output -- see builder.nix's mkDerivation
# for that merge) plus whatever `extraContents` the caller asked to bundle
# alongside it (e.g. cacert, tzdata, a shell for debugging).
{ pkgs, lib, realDrv, allPayloads, extraContents, imageName, tag, entrypoint, cmd, env, workdir, exposedPorts, labels, user, maxLayers, created }:
let
  config = {
    Entrypoint = entrypoint;
    Cmd = cmd;
  }
  // lib.optionalAttrs (env != [ ]) { Env = env; }
  // lib.optionalAttrs (workdir != null) { WorkingDir = workdir; }
  // lib.optionalAttrs (user != null) { User = user; }
  // lib.optionalAttrs (labels != { }) { Labels = labels; }
  // lib.optionalAttrs (exposedPorts != [ ]) {
    # OCI image config wants ExposedPorts as an attrset of
    # "<port>/<protocol>" -> {} (an empty object per entry, not a boolean
    # or a real value -- the key's presence is the only thing that
    # matters, same shape `docker inspect` shows back).
    ExposedPorts = builtins.listToAttrs
      (map (p: { name = p; value = { }; }) exposedPorts);
  };
in
pkgs.dockerTools.buildLayeredImage ({
  name = imageName;
  inherit tag maxLayers config;
  contents = allPayloads ++ extraContents;
  meta = (realDrv.meta or { }) // { inherit (realDrv) pname version; };
} // lib.optionalAttrs (created != null) { inherit created; })
