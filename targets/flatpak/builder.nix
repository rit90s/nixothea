# nativeDerivationFactory: never actually called -- resolver.nix always
# emits an empty section, so there are never any dependencies to turn into
# pkgs.<name> values. Exists to satisfy the target interface.
#
# mkDerivation: "root" walks nodeDeps via collectDeps and turns every
# transitively-reachable node's own args into its own Flatpak `modules[]`
# entry (nested nodes first, root last -- not a real topological sort,
# same caveat as every other target's nested-node merge). "dependency" is
# already a real input of whatever consumed it -- the root build walks the
# full node tree regardless, so there's nothing extra to do there.
{ lib, collectDeps, appId, runtime, runtimeVersion, sdk, finishArgs, mainProgram }:
{
  nativeDerivationFactory = { pkgs, name, entry }:
    throw "nixothea flatpak target: does not support dependencies (got ${name})";

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        # "One combined build", same idea as every other target's nested-
        # node merge, just mapped onto Flatpak's own native concept of it:
        # every transitively-reachable node's own args become their own
        # module, nested nodes first, root last.
        moduleArgs = map (n: n.args) collected.nodes ++ [ args ];

        # A module's own source is optional-but-paired, same convention
        # as aur.nix's aurSource/aurSourceSha256 (not mandatory like
        # homebrew.nix's -- a Flatpak module's `sources` array can
        # legitimately be empty; nothing in the Flatpak manifest schema
        # itself requires a fetchable source the way Homebrew's Formula
        # class does).
        mkModule = a:
          let
            src = a.flatpakSource or null;
            sha = a.flatpakSourceSha256 or null;
          in
          assert lib.assertMsg ((src == null) == (sha == null))
            "nixothea flatpak target: ${a.pname} must set both flatpakSource and flatpakSourceSha256, or neither";
          {
            name = a.pname;
            buildsystem = "simple";
            build-commands = [
              (a.buildPhase or "")
              ("out=/app\n" + (a.installPhase or ""))
            ];
            sources = lib.optional (src != null) {
              type = "archive";
              url = src;
              sha256 = sha;
            };
          };

        manifest = {
          app-id = appId;
          inherit runtime sdk;
          runtime-version = runtimeVersion;
          command = mainProgram;
          finish-args = finishArgs;
          modules = map mkModule moduleArgs;
        };

        manifestFile = pkgs.writeText "${appId}.json" (builtins.toJSON manifest);
      in
      pkgs.runCommand "${args.pname}-flatpak" { } ''
        mkdir -p $out
        cp ${manifestFile} $out/${appId}.json
      ''
    else
      throw "nixothea flatpak target: unknown role ${role}";
}
