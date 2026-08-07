# A constructor: `nixothea.targets.appimage { icon = ...; }` returns a
# target. AppImages are fully self-contained (no host package manager
# involved), so this target doesn't participate in dependency resolution --
# `resolve` always emits an empty section, and the root build bundles
# whatever runtime closure it actually needs directly.
{ pkgs, mkTarget }:
let
  lib = pkgs.lib;

  # Official type-2 AppImage runtime stub, prepended to the squashfs
  # payload to make the result directly executable. nixpkgs doesn't
  # package this -- pkgs.appimageTools only wraps/extracts *existing*
  # AppImages (for running them on NixOS), it has no support for building
  # new ones, and there's no appimagetool/mkappimage/appimage-builder in
  # nixpkgs either. Pinned to a dated release (not the floating
  # "continuous" tag) so the fetch stays reproducible.
  runtime = pkgs.fetchurl {
    url = "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64";
    sha256 = "0396xi3km1yd0z4329lbjxmv82ddc40gd0x8hca0ylcj7i28pjig";
  };
in
{
  # Path to the icon shown in app launchers. The AppImage runtime itself
  # doesn't care -- it never parses the .desktop file, just execs AppRun --
  # so this only affects desktop integration. When null, the .desktop
  # file's Icon= is omitted instead of failing the build.
  icon ? null,

  # freedesktop.org Categories= for the .desktop file.
  categories ? [ "Utility" ],

  # squashfs compression algorithm for the payload. "gzip" builds fastest;
  # "xz"/"zstd" produce smaller AppImages at the cost of build time.
  compression ? "gzip",

  # Which binary under the root derivation's $out/bin/ the generated AppRun
  # execs. When null, resolved from $out/bin/: used directly if there's
  # exactly one entry, otherwise the build fails asking for mainProgram to
  # be set explicitly.
  mainProgram ? null,

  # Not yet implemented: embedding zsync update info requires patching an
  # ELF section into the runtime stub, which needs verifying against the
  # exact section layout the real appimagetool produces.
  updateInformation ? null,
}:
mkTarget {
  inherit lib;

  resolve = { pkgs, deps }:
    pkgs.writeShellApplication {
      name = "resolve-appimage";
      text = "echo '{}'";
    };

  # Never actually called: resolve above always emits an empty section, so
  # there are never any dependencies to turn into pkgs.<name> values. Exists
  # to satisfy the target interface.
  nativeDerivationFactory = { pkgs, name, entry }:
    throw "nixothea appimage target: does not support dependencies (got ${name})";

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps }:
    if role == "dependency" then
      # A node used as a buildInput of something else is already a real
      # dependency of that something's real build (see
      # wrap-mk-derivation.nix -- realDrv is unwrapped into the real
      # compile for real linking), which means it's already part of that
      # build's Nix closure. Since the root build below bundles its *full*
      # closure regardless, there's nothing extra to do here.
      realDrv
    else if role == "root" then
      let
        closureInfo = pkgs.closureInfo { rootPaths = [ realDrv ]; };

        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea appimage target: ${realDrv.pname} has no bin/ directory -- set mainProgram explicitly"
          else
            let bins = builtins.attrNames (builtins.readDir "${realDrv}/bin");
            in
            if builtins.length bins == 1 then
              builtins.head bins
            else
              throw "nixothea appimage target: ${realDrv.pname} ships ${toString (builtins.length bins)} binaries under bin/ -- set mainProgram explicitly";

        appRun = pkgs.writeText "AppRun" ''
          #!/bin/sh
          exec "$APPDIR${realDrv}/bin/${resolvedMainProgram}" "$@"
        '';

        iconExt = lib.last (lib.splitString "." (baseNameOf (toString icon)));

        desktopFile = pkgs.writeText "${realDrv.pname}.desktop" ''
          [Desktop Entry]
          Type=Application
          Name=${realDrv.pname}
          Exec=AppRun
          ${lib.optionalString (icon != null) "Icon=${realDrv.pname}"}
          Categories=${lib.concatStringsSep ";" categories};
        '';
      in
      assert lib.assertMsg (updateInformation == null)
        "nixothea appimage target: updateInformation is not yet implemented";
      pkgs.stdenv.mkDerivation {
        pname = "${realDrv.pname}-appimage";
        version = realDrv.version;
        dontUnpack = true;
        # The finished .AppImage starts with the runtime's own ELF header,
        # with the squashfs payload appended as trailing bytes the runtime
        # locates by scanning past its own known size. Nix's default fixup
        # phase would see that ELF header and run shrinkRPath/patchelf/
        # strip on it, which rewrite ELF sections in place and could
        # corrupt or displace that trailing data -- none of which benefits
        # an artifact that has to run unmodified on non-Nix systems anyway.
        dontFixup = true;
        nativeBuildInputs = [ pkgs.squashfsTools ];
        buildPhase = ''
          runHook preBuild

          appdir=AppDir
          mkdir -p "$appdir/nix/store"
          while IFS= read -r path; do
            cp -a --parents "$path" "$appdir"
          done < ${closureInfo}/store-paths

          install -Dm755 ${appRun} "$appdir/AppRun"
          install -Dm644 ${desktopFile} "$appdir/${realDrv.pname}.desktop"
          ${lib.optionalString (icon != null)
            ''install -Dm644 ${icon} "$appdir/${realDrv.pname}.${iconExt}"''}

          mksquashfs "$appdir" payload.squashfs -root-owned -noappend -comp ${compression}
          cat ${runtime} payload.squashfs > "${realDrv.pname}-${realDrv.version}-x86_64.AppImage"
          chmod +x "${realDrv.pname}-${realDrv.version}-x86_64.AppImage"

          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp ./*.AppImage $out/
          runHook postInstall
        '';
      }
    else
      throw "nixothea appimage target: unknown role ${role}";
}
