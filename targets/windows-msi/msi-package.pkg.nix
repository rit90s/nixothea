# Builds the real .msi via wixl, from the already-merged payload of
# every transitively-reachable node's own bin/ (see builder.nix's
# mkDerivation for that merge).
{ pkgs, lib, realDrv, arch, upgradeCode, publisher, license, allPayloads, allBinFiles, resolvedMainProgram, extraWxsXml, description }:
let
  # Deterministically derives a syntactically-valid GUID (8-4-4-4-12 hex
  # groups -- wixl/msiexec don't check RFC4122 version/variant bits) from
  # an arbitrary string, so identity stays stable across rebuilds without
  # hand-minting one per file.
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

  # Wraps plain text into a minimal valid RTF document -- passed through
  # unchanged if it already looks like RTF. See default.nix's `license`
  # comment for why: MSI's license control crashes msiexec outright on
  # non-RTF input, verified empirically.
  toRtf = text:
    if lib.hasPrefix "{\\rtf" text then
      text
    else
      let
        escaped = lib.replaceStrings [ "\\" "{" "}" ] [ "\\\\" "\\{" "\\}" ] text;
        withPars = lib.concatStringsSep "\\par\n" (lib.splitString "\n" escaped);
      in
      "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Arial;}}\\f0\\fs18 ${withPars}}";

  productCode = mkGuid "${upgradeCode}:product:${realDrv.version}";

  # Must end up on disk literally named "License.rtf" -- wixl's bundled
  # WelcomeEulaDlg.wxs (part of --ext ui) hardcodes that exact relative
  # filename (verified by reading wixl's source), so this is copied into
  # place by buildPhase below rather than referenced by its own path.
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
  # Same reasoning as windows-exe's dontFixup: an .msi is a
  # compound-file-binary-format container wixl produced, not something
  # Linux's PE-aware strip tooling should ever touch.
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
