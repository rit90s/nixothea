# A constructor: `nixothea.targets.windowsMsi { upgradeCode = "..."; }`
# returns a target that builds a real WiX-format .msi via `wixl` (from
# msitools) -- WiX itself isn't packaged for Linux, but msitools is a
# from-scratch reimplementation of a WiX-compatible compiler that runs
# natively on Linux, no Wine needed to *build* the .msi (only to test
# running it, which this target's development used `wine`'s own
# `msiexec`/`wine` for). Same cross-compilation requirement as
# windows-exe.nix -- see that file's header comment for why `pkgs` here
# must be a Windows cross pkgs, why dependencies are a transparent
# pass-through to `pkgs.<name>`, and why DLL bundling needs no extra work
# (nixpkgs' own mingw setup hook already symlinks every actually-needed
# DLL into a binary's own $out/bin/, transitively).
{ pkgs, mkTarget, collectDeps }:
let
  # Only `.lib` is used from this construction-time `pkgs` -- see
  # windows-exe.nix's header comment for why platform-dependent things
  # instead read mkDerivation's own `pkgs` parameter (the caller's
  # buildTarget-time one).
  lib = pkgs.lib;

  # Only verified for x86_64 (full real build+install+run under Wine);
  # i686 by evaluation only. Checks hostPlatform.kernel, not just cpu --
  # see windows-exe.nix's archFor comment for why.
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

  # Deterministically derives a syntactically-valid GUID (8-4-4-4-12 hex
  # groups -- wixl/msiexec don't check RFC4122 version/variant bits, just
  # the shape) from an arbitrary string, so component/product identity
  # stays stable and reproducible across rebuilds without the caller
  # having to hand-mint one per file. Collisions are not a practical
  # concern (sha256-sized input space) for identifiers scoped to a single
  # package's own file list.
  mkGuid = seed:
    let h = builtins.hashString "sha256" seed;
    in lib.concatStringsSep "-" [
      (builtins.substring 0 8 h)
      (builtins.substring 8 4 h)
      (builtins.substring 12 4 h)
      (builtins.substring 16 4 h)
      (builtins.substring 20 12 h)
    ];

  # WiX Identifiers can't start with a digit and only allow
  # [A-Za-z0-9_.], so filenames with dots/dashes/pluses (e.g.
  # "libgcc_s_seh-1.dll") need sanitizing to be used as Component/File
  # Ids.
  sanitizeId = name:
    let s = lib.replaceStrings [ "-" "+" ] [ "_" "_" ] name;
    in if builtins.match "[0-9].*" s != null then "_${s}" else s;

  # Wraps plain text into a minimal valid RTF document (escaping RTF's own
  # control characters, converting newlines to \par) -- passed through
  # unchanged if it already looks like RTF. See the `license` argument's
  # comment below for why this exists: MSI's license control crashes
  # msiexec outright on non-RTF input, verified empirically.
  toRtf = text:
    if lib.hasPrefix "{\\rtf" text then
      text
    else
      let
        escaped = lib.replaceStrings [ "\\" "{" "}" ] [ "\\\\" "\\{" "\\}" ] text;
        withPars = lib.concatStringsSep "\\par\n" (lib.splitString "\n" escaped);
      in
      "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Arial;}}\\f0\\fs18 ${withPars}}";
in
{
  # Mandatory, no default -- same reasoning as `repos`/`releasever` on the
  # dnf-based targets: MSI's upgrade-detection model keys off this GUID
  # staying constant across every version of a given app forever, so
  # silently generating one would be exactly the kind of implicit,
  # hard-to-undo choice a caller should make explicitly (get it wrong and
  # MSI's upgrade/uninstall behavior silently breaks for existing
  # installs). `productCode` (which, unlike UpgradeCode, *should* change
  # per version under real MSI semantics) is deterministically derived
  # from this plus the package version instead of also being manual or
  # left to wixl's non-reproducible "*" auto-generation -- nothing
  # arbitrary is being decided on the caller's behalf, it's a mechanical
  # function of information the caller already fully controls.
  upgradeCode,

  publisher ? null,
  mainProgram ? null,

  # Optional license text (or a path to a license file) shown as an
  # accept/decline page before install, via wixl's bundled WixUI_Minimal
  # extension (verified this ships as a real usable extension, not just a
  # WiX-on-Windows-only feature -- `wixl --ext ui` pulls in the same
  # dialog set real WiX ships). Unlike windows-exe.nix's license (which
  # NSIS displays as either plain text or .rtf, no conversion needed),
  # MSI's ScrollableText control genuinely requires RTF -- verified
  # empirically that feeding it plain text crashes msiexec outright
  # (invalid RTF parsing, not a graceful fallback). So a string that
  # doesn't already look like RTF (start with "{\rtf") is auto-wrapped
  # into a minimal valid RTF document; a string that's already RTF, or a
  # path to a .rtf file, is used as-is. When null (the default), no
  # license page is added -- behavior unchanged from before this option
  # existed, including for silent (/qn) installs either way, since the
  # license dialog only exists in the interactive UI sequence.
  license ? null,

  # Raw WiX XML spliced in just before </Product>, for anything not
  # covered above (extra <Feature>/<Property>/<UI>/<WixVariable> etc.) --
  # same escape-hatch/trust model as windows-exe.nix's extraNsisScript.
  # Empty by default (no-op).
  extraWxsXml ? "",
}:
mkTarget {
  inherit lib;

  # See windows-exe.nix's resolve for why buildPackages is required here.
  resolve = { pkgs, deps }:
    pkgs.buildPackages.writeShellApplication {
      name = "resolve-windows-msi";
      text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
    };

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
        # buildPhase below) -- if two payloads both ship the same DLL
        # name, only one Component is needed since only one file ends up
        # on disk.
        allBinFiles = lib.unique (lib.concatMap
          (p: if builtins.pathExists "${p}/bin" then builtins.attrNames (builtins.readDir "${p}/bin") else [ ])
          allPayloads);

        productCode = mkGuid "${upgradeCode}:product:${realDrv.version}";

        # Must end up on disk literally named "License.rtf" -- wixl's
        # bundled WelcomeEulaDlg.wxs (part of --ext ui) hardcodes that
        # exact relative filename, resolved via wixl's default search path
        # (which always includes the build's own cwd -- verified by
        # reading wixl's source, not just guessing). So this is copied
        # into place by buildPhase below rather than referenced by its own
        # (hash-prefixed) store path.
        licenseRtfFile =
          if license == null then
            null
          else
            pkgs.writeText "License.rtf"
              (toRtf (if builtins.isPath license then builtins.readFile license else license));

        fileComponentsXml = lib.concatMapStringsSep "\n" (fname:
          let
            id = sanitizeId fname;
            guid = mkGuid "${upgradeCode}:file:${fname}";
          in ''
            <Component Id="Comp_${id}" Guid="${guid}" Win64="${arch.win64}">
              <File Id="File_${id}" Source="payload/${fname}" KeyPath="yes" />
            </Component>
          '') allBinFiles;

        fileComponentRefsXml = lib.concatMapStringsSep "\n"
          (fname: ''      <ComponentRef Id="Comp_${sanitizeId fname}" />'')
          allBinFiles;

        description = args.meta.description or "";

        wxsFile = pkgs.writeText "${realDrv.pname}.wxs" ''
          <?xml version="1.0" encoding="utf-8"?>
          <Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
            <Product Id="${productCode}"
                     Name="${realDrv.pname}"
                     Language="1033"
                     Version="${realDrv.version}"
                     Manufacturer="${if publisher != null then publisher else realDrv.pname}"
                     UpgradeCode="${upgradeCode}">
              <Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine" Description="${description}" />
              <Media Id="1" Cabinet="payload.cab" EmbedCab="yes" />

              <Upgrade Id="${upgradeCode}">
                <UpgradeVersion Minimum="0.0.0" IncludeMinimum="yes"
                                Maximum="${realDrv.version}" IncludeMaximum="no"
                                Property="OLDERVERSIONBEINGUPGRADED" />
              </Upgrade>
              <InstallExecuteSequence>
                <RemoveExistingProducts Before="InstallInitialize" />
              </InstallExecuteSequence>

              <Directory Id="TARGETDIR" Name="SourceDir">
                <Directory Id="${arch.wixProgramFilesDir}">
                  <Directory Id="INSTALLDIR" Name="${realDrv.pname}">
            ${fileComponentsXml}
                  </Directory>
                </Directory>
                <Directory Id="ProgramMenuFolder">
                  <Directory Id="AppProgramsFolder" Name="${realDrv.pname}">
                    <Component Id="ShortcutComponent" Guid="${mkGuid "${upgradeCode}:shortcut"}">
                      <Shortcut Id="AppShortcut" Name="${realDrv.pname}"
                                Target="[INSTALLDIR]${resolvedMainProgram}.exe"
                                WorkingDirectory="INSTALLDIR" />
                      <RemoveFolder Id="RemoveAppProgramsFolder" On="uninstall" />
                      <RegistryValue Root="HKCU" Key="Software\${realDrv.pname}"
                                     Name="installed" Type="integer" Value="1" KeyPath="yes" />
                    </Component>
                  </Directory>
                </Directory>
              </Directory>

              <Feature Id="MainFeature" Title="${realDrv.pname}" Level="1">
          ${fileComponentRefsXml}
                <ComponentRef Id="ShortcutComponent" />
              </Feature>

          ${lib.optionalString (licenseRtfFile != null) ''      <UIRef Id="WixUI_Minimal" />''}
          ${extraWxsXml}
            </Product>
          </Wix>
        '';
      in
      pkgs.stdenv.mkDerivation {
        pname = "${realDrv.pname}-windows-msi";
        version = realDrv.version;
        dontUnpack = true;
        # Same reasoning as windows-exe.nix's dontFixup: an .msi is a
        # compound-file-binary-format container wixl produced, not
        # something Linux's PE-aware strip tooling should ever touch.
        dontFixup = true;
        nativeBuildInputs = [ pkgs.msitools ];
        buildPhase = ''
          runHook preBuild
          mkdir -p payload
          ${lib.concatMapStringsSep "\n" (p: ''
            if [ -d "${p}/bin" ]; then
              cp -rL "${p}/bin/." payload/
            fi
          '') allPayloads}
          cp ${wxsFile} installer.wxs
          ${lib.optionalString (licenseRtfFile != null) "cp ${licenseRtfFile} License.rtf"}
          wixl -a ${arch.wixArch} ${lib.optionalString (licenseRtfFile != null) "--ext ui"} -o "${realDrv.pname}-${realDrv.version}-setup.msi" installer.wxs
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp ./*.msi $out/
          runHook postInstall
        '';
      }
    else
      throw "nixothea windowsMsi target: unknown role ${role}";
}
