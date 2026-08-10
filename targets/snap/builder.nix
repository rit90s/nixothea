# nativeDerivationFactory: see extracted-dependency.pkg.nix.
#
# mkDerivation: "root" builds one combined payload (see payload.pkg.nix)
# and wraps it with the generated manifest -- the real-build equivalent of
# every other target's nested-node merge. "dependency" is already a real
# input of whatever consumed it.
{ lib, collectDeps, architecture, base, confinement, grade }:
let
  licenseName = l: if builtins.isString l then l else (l.spdxId or l.shortName or null);
  licenseNames = l:
    if l == null then [ ]
    else if builtins.isList l then lib.filter (x: x != null) (map licenseName l)
    else lib.filter (x: x != null) [ (licenseName l) ];

  # Snap Store names: lowercase letters/digits/hyphens, must start with a
  # letter. Best-effort, not a full validator -- see default.nix's header
  # comment.
  sanitizeSnapName = name:
    let
      lowered = lib.toLower name;
      dashed = lib.stringAsChars (c: if builtins.match "[a-z0-9]" c != null then c else "-") lowered;
      segments = lib.filter (s: builtins.isString s && s != "") (builtins.split "-+" dashed);
      joined = lib.concatStringsSep "-" segments;
    in
    if joined == "" then "x"
    else if builtins.match "[a-z].*" joined != null then joined
    else "x-" + joined;

  multiarchTriplets = {
    amd64 = "x86_64-linux-gnu";
    arm64 = "aarch64-linux-gnu";
    armhf = "arm-linux-gnueabihf";
    i386 = "i386-linux-gnu";
  };

  # Same real, standard FHS dynamic-linker paths as deb's own
  # `interpreters` map -- the base snap provides a normal Ubuntu
  # userspace, so these are the same paths a real `.deb`'s binaries
  # expect on a real Debian-family machine.
  interpreters = {
    amd64 = "/lib64/ld-linux-x86-64.so.2";
    arm64 = "/lib/ld-linux-aarch64.so.1";
    armhf = "/lib/ld-linux-armhf.so.3";
    i386 = "/lib/ld-linux.so.2";
  };

  multiarchTriplet = multiarchTriplets.${architecture} or
    (throw "nixothea snap target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames multiarchTriplets)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea snap target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");
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

        allDependencyDerivations = dependencyDeps ++ collected.dependencies;

        # "One combined payload", the real-build equivalent of every other
        # target's nested-node merge: every transitively-reachable node's
        # own real build output, plus the root's own, copied into one
        # payload tree.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        # Per-package, like mainProgram was in this target's first
        # version -- but optional now, not mandatory. Free to auto-detect
        # once this target always does a real Nix-level compile anyway
        # (same reasoning as appimage.nix's own auto-detect): the first
        # version had to make it mandatory specifically to avoid forcing
        # an unwanted build via "${realDrv}/bin" string interpolation,
        # which no longer applies once realDrv is always built for real
        # regardless.
        mainProgram = args.mainProgram or null;
        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea snap target: ${realDrv.pname} has no bin/ directory -- set mainProgram explicitly"
          else
            let bins = builtins.attrNames (builtins.readDir "${realDrv}/bin");
            in
            if builtins.length bins == 1 then
              builtins.head bins
            else
              throw "nixothea snap target: ${realDrv.pname} ships ${toString (builtins.length bins)} binaries under bin/ -- set mainProgram explicitly";

        meta = args.meta or { };
        licenses = licenseNames (meta.license or null);
        licenseLine = if licenses == [ ] then null else lib.concatStringsSep " AND " licenses;

        snapPlugs = args.snapPlugs or [ ];
        snapName = sanitizeSnapName args.pname;

        payload = import ./payload.pkg.nix {
          inherit pkgs lib realDrv allPayloads allDependencyDerivations targetInterpreter;
        };

        manifest = {
          name = snapName;
          version = args.version;
          inherit base confinement grade;
          platforms.${architecture} = { build-on = [ architecture ]; build-for = [ architecture ]; };
          parts.main = {
            plugin = "dump";
            source = "payload";
            source-type = "local";
          };
          apps.${snapName} = {
            command = "bin/${resolvedMainProgram}";
            plugs = snapPlugs;
          };
        }
        // lib.optionalAttrs (meta ? description) {
          summary = meta.description;
          description = meta.description;
        }
        // lib.optionalAttrs (licenseLine != null) { license = licenseLine; };

        manifestFile = pkgs.writeText "snapcraft.yaml" (builtins.toJSON manifest);
      in
      pkgs.runCommand "${args.pname}-snap" { } ''
        mkdir -p $out/snap
        cp ${manifestFile} $out/snap/snapcraft.yaml
        cp -a ${payload} $out/payload
      ''
    else
      throw "nixothea snap target: unknown role ${role}";
}
