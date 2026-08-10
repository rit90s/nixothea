# nativeDerivationFactory: entry.name is a real nixpkgs attribute name in
# the cross pkgs set (top-level only; no dotted-path lookup for nested
# attrsets).
#
# mkDerivation: "root" builds one combined NSIS installer (see
# exe-package.pkg.nix), same nested-node merge as every other target.
# "dependency" is already a real input of whatever consumed it -- nixpkgs'
# mingw setup hook already symlinked whatever DLLs it needs into its own
# bin/, which the root build folds in like everything else.
{ lib, collectDeps, publisher, mainProgram, license, extraNsisScript }:
let
  # Only verified for these two -- mingw32 by evaluation only (i686 was
  # never actually built/run-tested this session), mingwW64 by a full
  # real build+install+run under Wine. aarch64-windows cross support
  # exists in nixpkgs but wasn't touched here. Checks hostPlatform.kernel,
  # not just cpu: x86_64-linux and x86_64-windows share the same cpu name
  # ("x86_64"), so a cpu-only check wouldn't catch a caller accidentally
  # passing native pkgs to buildTarget instead of a cross one.
  archFor = pkgs:
    let
      cpuName = pkgs.stdenv.hostPlatform.parsed.cpu.name;
      archNames = {
        x86_64 = { programFilesVar = "PROGRAMFILES64"; };
        i686 = { programFilesVar = "PROGRAMFILES"; };
      };
    in
    if pkgs.stdenv.hostPlatform.parsed.kernel.name != "windows" then
      throw "nixothea windowsExe target: pkgs passed to buildTarget must be a Windows cross pkgs (e.g. pkgsCross.mingwW64), got hostPlatform '${pkgs.stdenv.hostPlatform.system}'"
    else
      archNames.${cpuName} or
        (throw "nixothea windowsExe target: unsupported/unverified target architecture '${cpuName}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames archNames)})");
in
{
  nativeDerivationFactory = { pkgs, name, entry }:
    pkgs.${entry.name} or
      (throw "nixothea windowsExe target: no such nixpkgs package '${entry.name}' (for dependency '${name}')");

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        arch = archFor pkgs;

        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        # "One combined installer", same idea as every other target's
        # nested-node merge: every transitively-reachable node's own
        # bin/ (exe + auto-symlinked DLLs) gets folded into one flat
        # payload directory, not a separate installer per node.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea windowsExe target: ${realDrv.pname} has no bin/ directory -- set mainProgram explicitly"
          else
            let
              exes = builtins.filter (lib.hasSuffix ".exe")
                (builtins.attrNames (builtins.readDir "${realDrv}/bin"));
            in
            if builtins.length exes == 1 then
              lib.removeSuffix ".exe" (builtins.head exes)
            else
              throw "nixothea windowsExe target: ${realDrv.pname} ships ${toString (builtins.length exes)} .exe file(s) under bin/ -- set mainProgram explicitly";
      in
      import ./exe-package.pkg.nix {
        inherit pkgs lib realDrv arch publisher license extraNsisScript allPayloads resolvedMainProgram;
      }
    else
      throw "nixothea windowsExe target: unknown role ${role}";
}
