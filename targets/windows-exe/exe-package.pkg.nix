# Builds the real NSIS-based Windows installer (.exe) via makensis, from
# the already-merged payload of every transitively-reachable node's own
# bin/ (see builder.nix's mkDerivation for that merge).
{ pkgs, lib, realDrv, arch, publisher, license, extraNsisScript, allPayloads, resolvedMainProgram }:
let
  uninstallKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${realDrv.pname}";

  # NSIS variable reference (e.g. "$PROGRAMFILES64") built as a plain Nix
  # string first, then interpolated normally below -- writing the
  # literal `$` directly adjacent to a `${...}` interpolation in a Nix
  # indented string (`"$${arch...}"`) does NOT produce "literal $ +
  # interpolated value" the way it might look like it should; verified
  # empirically that it instead passes through as the literal text
  # `$${arch...}`, unexpanded.
  programFilesRef = "$" + arch.programFilesVar;

  licenseFile =
    if license == null then null
    else if builtins.isPath license then license
    else pkgs.writeText "${realDrv.pname}-license.txt" license;

  installerScript = pkgs.writeText "${realDrv.pname}.nsi" ''
    Unicode true
    OutFile "${realDrv.pname}-${realDrv.version}-setup.exe"
    InstallDir "${programFilesRef}\${realDrv.pname}"
    Name "${realDrv.pname}"
    RequestExecutionLevel admin

    ${extraNsisScript}
    ${lib.optionalString (licenseFile != null) ''
      !include "MUI2.nsh"
      !insertmacro MUI_PAGE_LICENSE "${licenseFile}"
      !insertmacro MUI_LANGUAGE "English"
    ''}
    Page directory
    Page instfiles
    UninstPage uninstConfirm
    UninstPage instfiles

    Section "Install"
      SetOutPath "$INSTDIR"
      File /r "payload\*.*"
      CreateDirectory "$SMPROGRAMS\${realDrv.pname}"
      CreateShortcut "$SMPROGRAMS\${realDrv.pname}\${realDrv.pname}.lnk" "$INSTDIR\${resolvedMainProgram}.exe"
      CreateShortcut "$SMPROGRAMS\${realDrv.pname}\Uninstall.lnk" "$INSTDIR\uninstall.exe"
      WriteUninstaller "$INSTDIR\uninstall.exe"
      WriteRegStr HKLM "${uninstallKey}" "DisplayName" "${realDrv.pname}"
      WriteRegStr HKLM "${uninstallKey}" "DisplayVersion" "${realDrv.version}"
      WriteRegStr HKLM "${uninstallKey}" "UninstallString" '"$INSTDIR\uninstall.exe"'
      WriteRegStr HKLM "${uninstallKey}" "InstallLocation" "$INSTDIR"
    ${lib.optionalString (publisher != null) ''  WriteRegStr HKLM "${uninstallKey}" "Publisher" "${publisher}"''}
      WriteRegDWORD HKLM "${uninstallKey}" "NoModify" 1
      WriteRegDWORD HKLM "${uninstallKey}" "NoRepair" 1
    SectionEnd

    Section "Uninstall"
      RMDir /r "$INSTDIR"
      RMDir /r "$SMPROGRAMS\${realDrv.pname}"
      DeleteRegKey HKLM "${uninstallKey}"
    SectionEnd
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-windows-exe";
  version = realDrv.version;
  dontUnpack = true;
  # NSIS's own finished .exe embeds its installer script/data in a
  # format only makensis understands -- Linux's PE-aware strip (used
  # here since this derivation is built with the cross stdenv) doesn't
  # know about that and could corrupt it, the same class of risk
  # appimage.nix's dontFixup avoids for its runtime-stub-prefixed
  # .AppImage.
  dontFixup = true;
  nativeBuildInputs = [ pkgs.nsis ];
  buildPhase = ''
    runHook preBuild
    mkdir -p payload
    ${lib.concatMapStringsSep "\n" (p: ''
      if [ -d "${p}/bin" ]; then
        cp -rL "${p}/bin/." payload/
      fi
    '') allPayloads}
    cp ${installerScript} installer.nsi
    makensis installer.nsi
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp ./*.exe $out/
    runHook postInstall
  '';
}
