# Builds the real portable tarball: bundles realDrv's full Nix closure
# under a relocatable top-level directory, patches up the same ELF-
# interpreter/RPATH problem appimage-package.pkg.nix solves (a relocated
# Nix closure has no real /nix/store to resolve absolute paths against on
# the machine that extracts it), and tars the whole thing up behind a
# generated launcher script -- named after resolvedMainProgram itself
# (not e.g. "run.sh"), so extracting the tarball and running
# "./${resolvedMainProgram}" looks and feels like running the real binary
# directly, even though it's actually this wrapper. See builder.nix for
# the mainProgram-resolution logic that runs before this.
{ pkgs, lib, realDrv, closureInfo, resolvedMainProgram, compression }:
let
  compressors = {
    gzip = { ext = "tar.gz"; flag = "--gzip"; pkg = pkgs.gzip; };
    xz = { ext = "tar.xz"; flag = "--xz"; pkg = pkgs.xz; };
    zstd = { ext = "tar.zst"; flag = "--zstd"; pkg = pkgs.zstd; };
    none = { ext = "tar"; flag = ""; pkg = null; };
  };
  compressor = compressors.${compression} or
    (throw "nixothea tarball target: unsupported compression '${compression}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames compressors)})");

  pkgName = "${realDrv.pname}-${realDrv.version}";
in
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-tarball";
  version = realDrv.version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.gnutar pkgs.patchelf ]
    ++ lib.optional (compressor.pkg != null) compressor.pkg;
  buildPhase = ''
    runHook preBuild

    pkgdir="${pkgName}"
    mkdir -p "$pkgdir/nix/store"

    # Same relocation problem/fix as appimage-package.pkg.nix: every
    # binary in the bundled closure still has an absolute /nix/store/...
    # ELF interpreter/RPATH baked in from the machine that built it, which
    # won't resolve on a machine with no real /nix/store -- so the
    # launcher below execs the bundled dynamic linker directly with an
    # explicit --library-path, script-directory-relative, instead of
    # relying on the kernel's automatic (absolute-path) PT_INTERP dispatch.
    libpath=""
    while IFS= read -r path; do
      cp -a --parents "$path" "$pkgdir"
      if [ -d "$path/lib" ]; then
        libpath="\$SCRIPT_DIR$path/lib:$libpath"
      fi
    done < ${closureInfo}/store-paths
    libpath="''${libpath%:}"

    mainBinAbs="${realDrv}/bin/${resolvedMainProgram}"
    mainBin="$pkgdir$mainBinAbs"
    firstAbs="$mainBinAbs"
    extraArg=""
    scriptInterp=$(sed -n '1{/^#!/{s/^#![[:space:]]*//;s/[[:space:]].*//;p}}' "$mainBin")
    if [ -n "$scriptInterp" ] && [ "''${scriptInterp#${builtins.storeDir}/}" != "$scriptInterp" ]; then
      firstAbs="$scriptInterp"
      extraArg="\$SCRIPT_DIR$mainBinAbs"
    fi

    if interp=$(patchelf --print-interpreter "$pkgdir$firstAbs" 2>/dev/null); then
      loader="\$SCRIPT_DIR$interp --library-path \"$libpath\""
    else
      loader=""
    fi

    cat > "$pkgdir/${resolvedMainProgram}" <<LAUNCHER_EOF
    #!/bin/sh
    SCRIPT_DIR=\$(cd "\$(dirname "\$0")" && pwd)
    exec $loader "\$SCRIPT_DIR$firstAbs" $extraArg "\$@"
    LAUNCHER_EOF
    chmod 755 "$pkgdir/${resolvedMainProgram}"

    tar --owner=0 --group=0 --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
      ${compressor.flag} -cf "${pkgName}.${compressor.ext}" "$pkgdir"

    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp "${pkgName}.${compressor.ext}" $out/
    runHook postInstall
  '';
}
