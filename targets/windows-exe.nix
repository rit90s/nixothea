# A constructor: `nixothea.targets.windowsExe { }` returns a target that
# builds a real NSIS-based Windows installer (.exe). Unlike every other
# target, this one needs an actual cross-compiled Windows binary, not a
# repackaged Linux one -- so `pkgs` passed to this constructor (and to the
# `buildTarget` call it's used in) must itself be a Windows cross pkgs,
# e.g. `nixpkgs.legacyPackages.${system}.pkgsCross.mingwW64`. That means
# this target can't share a single `buildTarget` call with Linux-native
# targets (deb, rpm, ...) the way those can share with each other -- the
# same `definition` function has to actually compile differently for
# Windows, which needs its own `buildTarget` invocation with cross `pkgs`.
#
# Dependencies work like the `nix` target's (see nix.nix): there's no
# Windows equivalent of apt/dnf to resolve arbitrary C library build
# dependencies against, but nixpkgs' own mingw cross package set already
# *is* a full, working answer -- `pkgsCross.mingwW64.zlib` is a real,
# correctly cross-compiled derivation. So dependencies are a transparent
# pass-through to `pkgs.<name>` (no lock file, no resolve step doing real
# work). DLL bundling happens for free: nixpkgs' own mingw setup hook
# already symlinks every actually-needed runtime DLL next to a binary's
# .exe in its own $out/bin/, transitively -- verified empirically (a
# 2-level dependency chain correctly propagated its DLL down to the final
# binary's own bin/, no extra effort needed here). So the whole payload is
# just `$out/bin/*` with symlinks dereferenced.
{ pkgs, mkTarget, collectDeps }:
let
  # Only `.lib` is used from this construction-time `pkgs` -- genuinely
  # platform-agnostic, so it doesn't matter whether flake.nix constructed
  # this target with native or cross pkgs. Everything that actually
  # depends on the target platform (nsis, hostPlatform, ...) instead
  # reads it from mkDerivation's own `pkgs` parameter below, which is the
  # *caller's* buildTarget-time `pkgs` -- the one that actually has to be
  # cross pkgs for any of this to produce real Windows binaries.
  lib = pkgs.lib;

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
  publisher ? null,

  # Which binary under the root derivation's $out/bin/ becomes the
  # installed app's entry point (Start Menu shortcut target). When null,
  # resolved the same way appimage.nix does: used directly if bin/ has
  # exactly one .exe, otherwise the build fails asking for this to be set
  # explicitly.
  mainProgram ? null,

  # Optional license text (or a path to a license file) shown as an
  # accept/decline page before install. A Nix path is used as-is; a string
  # is written out via writeText. NSIS's MUI_PAGE_LICENSE displays either
  # plain text or .rtf as given -- no format conversion needed here (unlike
  # windows-msi.nix's license, which has to defend against a real msiexec
  # crash on non-RTF input; verified NSIS has no equivalent landmine).
  # When null (the default), no license page is added -- behavior is
  # unchanged from before this option existed.
  license ? null,

  # Raw NSIS script text spliced into the generated .nsi right after the
  # standard header directives (Unicode/OutFile/InstallDir/Name/
  # RequestExecutionLevel) and before the Page declarations (including the
  # license page above, if set). Lets a caller add their own !define/
  # !include, extra Page entries, custom Sections, Functions, icons,
  # version info, etc. without nixothea needing to model every NSIS
  # feature -- same trust model as any other caller-supplied builder
  # function in nixothea: invalid NSIS here just fails the caller's own
  # build. Empty by default (no-op).
  extraNsisScript ? "",
}:
mkTarget {
  inherit lib;

  # Nothing to resolve against a live registry -- see the pass-through
  # rationale above.
  # `pkgs.buildPackages.*`, not `pkgs.*`: this script needs to actually
  # run on the build machine via `nix run`, but `pkgs` here is
  # buildTarget/mkResolver's own (Windows cross) pkgs -- plain
  # `pkgs.writeShellApplication` would try to build the wrapper itself
  # *for Windows* (verified empirically: it fails outright, evaluating a
  # derivation tagged with an unbuildable "system"), since Nix's usual
  # automatic build/host splicing only kicks in for buildInputs/
  # nativeBuildInputs lists, not a directly-called package function like
  # this.
  resolve = { pkgs, deps }:
    pkgs.buildPackages.writeShellApplication {
      name = "resolve-windows-exe";
      text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
    };

  # entry.name is a real nixpkgs attribute name in the cross pkgs set
  # (top-level only; no dotted-path lookup for nested attrsets).
  nativeDerivationFactory = { pkgs, name, entry }:
    pkgs.${entry.name} or
      (throw "nixothea windowsExe target: no such nixpkgs package '${entry.name}' (for dependency '${name}')");

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      # Already a real input of whatever consumed it -- nixpkgs' mingw
      # setup hook already symlinked whatever DLLs it needs into its own
      # bin/, which the root build below folds in like everything else.
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

        uninstallKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${realDrv.pname}";

        # NSIS variable reference (e.g. "$PROGRAMFILES64") built as a
        # plain Nix string first, then interpolated normally below --
        # writing the literal `$` directly adjacent to a `${...}`
        # interpolation in a Nix indented string (`"$${arch...}"`) does
        # NOT produce "literal $ + interpolated value" the way it might
        # look like it should; verified empirically that it instead
        # passes through as the literal text `$${arch...}`, unexpanded.
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
        # format only makensis understands -- Linux's PE-aware strip
        # (used here since this derivation is built with the cross
        # stdenv) doesn't know about that and could corrupt it, the same
        # class of risk appimage.nix's dontFixup avoids for its
        # runtime-stub-prefixed .AppImage.
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
    else
      throw "nixothea windowsExe target: unknown role ${role}";
}
