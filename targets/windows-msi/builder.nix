# nativeDerivationFactory: same as windows-exe's -- entry.name is a real
# top-level nixpkgs attribute name in the cross pkgs set.
#
# mkDerivation: "root" builds one combined .msi via wixl (see
# msi-package.pkg.nix), same nested-node merge as every other target.
# "dependency" is already a real input of whatever consumed it, same
# reasoning as windows-exe.
{ lib, collectDeps, upgradeCode, publisher, mainProgram, license, extraWxsXml }:
let
  # Only verified for x86_64 (full real build+install+run under Wine);
  # i686 by evaluation only. Checks hostPlatform.kernel, not just cpu --
  # see windows-exe's archFor comment for why.
  archFor = pkgs:
    let
      cpuName = pkgs.stdenv.hostPlatform.parsed.cpu.name;
      archNames = {
        x86_64 = { wixArch = "x64"; wixProgramFilesDir = "ProgramFiles64Folder"; win64 = "yes"; };
        i686 = { wixArch = "x86"; wixProgramFilesDir = "ProgramFilesFolder"; win64 = "no"; };
      };
    in
    if pkgs.stdenv.hostPlatform.parsed.kernel.name != "windows" then
      throw "nixothea windowsMsi target: pkgs passed to buildTarget must be a Windows cross pkgs (e.g. pkgsCross.mingwW64), got hostPlatform '${pkgs.stdenv.hostPlatform.system}'"
    else
      archNames.${cpuName} or
        (throw "nixothea windowsMsi target: unsupported/unverified target architecture '${cpuName}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames archNames)})");
in
{
  nativeDerivationFactory = { pkgs, name, entry }:
    pkgs.${entry.name} or
      (throw "nixothea windowsMsi target: no such nixpkgs package '${entry.name}' (for dependency '${name}')");

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        arch = archFor pkgs;

        collected = collectDeps { inherit lib; nodes = nodeDeps; };
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea windowsMsi target: ${realDrv.pname} has no bin/ directory -- set mainProgram explicitly"
          else
            let
              exes = builtins.filter (lib.hasSuffix ".exe")
                (builtins.attrNames (builtins.readDir "${realDrv}/bin"));
            in
            if builtins.length exes == 1 then
              lib.removeSuffix ".exe" (builtins.head exes)
            else
              throw "nixothea windowsMsi target: ${realDrv.pname} ships ${toString (builtins.length exes)} .exe file(s) under bin/ -- set mainProgram explicitly";

        # Deduped final filenames, matching what actually lands in the
        # flat payload/ dir after every payload's bin/ is merged in (see
        # msi-package.pkg.nix's buildPhase) -- if two payloads both ship
        # the same DLL name, only one Component is needed since only one
        # file ends up on disk.
        allBinFiles = lib.unique (lib.concatMap
          (p: if builtins.pathExists "${p}/bin" then builtins.attrNames (builtins.readDir "${p}/bin") else [ ])
          allPayloads);

        description = args.meta.description or "";
      in
      import ./msi-package.pkg.nix {
        inherit pkgs lib realDrv arch upgradeCode publisher license allPayloads allBinFiles
          resolvedMainProgram extraWxsXml description;
      }
    else
      throw "nixothea windowsMsi target: unknown role ${role}";
}
