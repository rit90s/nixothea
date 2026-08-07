# A constructor: `nixothea.targets.appimage { icon = ...; }` returns a
# target. AppImages are fully self-contained (no host package manager
# involved), so this target doesn't participate in dependency resolution --
# `resolve` always emits an empty section, and `mkDerivation` bundles
# whatever runtime closure the built package actually needs directly.
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

  # Which binary under the wrapped derivation's $out/bin/ the generated
  # AppRun execs. When null, resolved from $out/bin/: used directly if
  # there's exactly one entry, otherwise the build fails asking for
  # mainProgram to be set explicitly.
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

  mkDerivation = { pkgs, lockSection }: args:
    let
      drv = pkgs.stdenv.mkDerivation args;
      closureInfo = pkgs.closureInfo { rootPaths = [ drv ]; };

      resolvedMainProgram =
        if mainProgram != null then
          mainProgram
        else if !(builtins.pathExists "${drv}/bin") then
          throw "nixothea appimage target: ${args.pname} has no bin/ directory -- set mainProgram explicitly"
        else
          let bins = builtins.attrNames (builtins.readDir "${drv}/bin");
          in
          if builtins.length bins == 1 then
            builtins.head bins
          else
            throw "nixothea appimage target: ${args.pname} ships ${toString (builtins.length bins)} binaries under bin/ -- set mainProgram explicitly";

      appRun = pkgs.writeText "AppRun" ''
        #!/bin/sh
        exec "$APPDIR${drv}/bin/${resolvedMainProgram}" "$@"
      '';

      iconExt = lib.last (lib.splitString "." (baseNameOf (toString icon)));

      desktopFile = pkgs.writeText "${args.pname}.desktop" ''
        [Desktop Entry]
        Type=Application
        Name=${args.pname}
        Exec=AppRun
        ${lib.optionalString (icon != null) "Icon=${args.pname}"}
        Categories=${lib.concatStringsSep ";" categories};
      '';
    in
    assert lib.assertMsg (updateInformation == null)
      "nixothea appimage target: updateInformation is not yet implemented";
    pkgs.stdenv.mkDerivation {
      pname = "${args.pname}-appimage";
      version = args.version;
      dontUnpack = true;
      # The finished .AppImage starts with the runtime's own ELF header,
      # with the squashfs payload appended as trailing bytes the runtime
      # locates by scanning past its own known size. Nix's default fixup
      # phase would see that ELF header and run shrinkRPath/patchelf/strip
      # on the file, which rewrite ELF sections in place and could corrupt
      # or displace that trailing data -- none of which benefits an
      # artifact that has to run unmodified on non-Nix systems anyway.
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
        install -Dm644 ${desktopFile} "$appdir/${args.pname}.desktop"
        ${lib.optionalString (icon != null)
          ''install -Dm644 ${icon} "$appdir/${args.pname}.${iconExt}"''}

        mksquashfs "$appdir" payload.squashfs -root-owned -noappend -comp ${compression}
        cat ${runtime} payload.squashfs > "${args.pname}-${args.version}-x86_64.AppImage"
        chmod +x "${args.pname}-${args.version}-x86_64.AppImage"

        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp ./*.AppImage $out/
        runHook postInstall
      '';
    };
}
