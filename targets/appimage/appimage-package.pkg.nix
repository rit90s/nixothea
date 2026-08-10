# Builds the real .AppImage: bundles realDrv's full Nix closure, patches
# up the ELF-interpreter/RPATH problem a relocated Nix closure has on a
# machine with no real /nix/store, and squashes it all together behind
# the real AppImage type-2 runtime stub. See builder.nix for the
# `updateInformation`/mainProgram-resolution logic that runs before this.
{ pkgs, lib, runtime, realDrv, closureInfo, resolvedMainProgram, icon, iconExt, desktopFile, compression }:
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-appimage";
  version = realDrv.version;
  dontUnpack = true;
  # The finished .AppImage starts with the runtime's own ELF header, with
  # the squashfs payload appended as trailing bytes the runtime locates
  # by scanning past its own known size. Nix's default fixup phase would
  # see that ELF header and run shrinkRPath/patchelf/strip on it, which
  # rewrite ELF sections in place and could corrupt or displace that
  # trailing data -- none of which benefits an artifact that has to run
  # unmodified on non-Nix systems anyway.
  dontFixup = true;
  # patchelf: not for rewriting anything in place (dontFixup above
  # already opts out of that) -- just to read back the interpreter path
  # AppRun needs to invoke explicitly, see below.
  nativeBuildInputs = [ pkgs.squashfsTools pkgs.patchelf ];
  buildPhase = ''
    runHook preBuild

    appdir=AppDir
    mkdir -p "$appdir/nix/store"
    # Bundling the closure under AppDir/nix/store/... makes it reachable
    # *relative to $APPDIR* (the mountpoint/extraction dir the real
    # AppImage runtime sets at run time -- see the "$APPDIR .../bin/..."
    # line below), but every binary in that closure still has its ELF
    # interpreter and RPATH baked in as *absolute* /nix/store/... paths
    # from the machine that built it. The kernel resolves PT_INTERP (and
    # a real loader resolves RPATH) against the real root filesystem,
    # not relative to wherever AppRun happened to exec from -- so on a
    # machine with no real /nix/store, those absolute lookups fail even
    # though a copy of the exact same content is sitting right there
    # under $APPDIR/nix/store/... (verified empirically: this genuinely
    # fails a real "no /nix" bwrap sandbox run without the fix below,
    # with a plain "not found" exec error). The fix used by every
    # relocatable-Nix-closure tool: don't rely on the kernel's automatic
    # PT_INTERP dispatch at all -- exec the bundled dynamic linker
    # *directly* as a program (ld.so accepts the real binary as its own
    # argument), passing an explicit --library-path built from every
    # closure path that has a lib/ dir, all $APPDIR-relative. RPATH
    # becomes irrelevant this way: ld.so's own baked-in RPATH search
    # still runs first and simply finds nothing at the (nonexistent)
    # absolute paths, falling through to --library-path, which does
    # resolve since it's $APPDIR-relative to content that's actually
    # there.
    libpath=""
    while IFS= read -r path; do
      cp -a --parents "$path" "$appdir"
      if [ -d "$path/lib" ]; then
        libpath="\$APPDIR$path/lib:$libpath"
      fi
    done < ${closureInfo}/store-paths
    libpath="''${libpath%:}"

    # What AppRun should actually exec *first*: normally mainBin itself,
    # but if mainBin is a script, the kernel would resolve its shebang
    # and exec *that* interpreter first (with mainBin as an argument) --
    # and patchShebangs already rewrote a plain "#!/bin/sh" into an
    # absolute /nix/store/... path during realDrv's own (normal,
    # un-dontFixup'd) build, the exact same problem as an ELF's
    # PT_INTERP, for the exact same reason. Verified empirically: without
    # accounting for this, a bundled script fails a real "no /nix" run
    # with a "not found" exec error even after the ELF-interpreter fix
    # below is applied to mainBin alone, because the chain doesn't stop
    # at mainBin -- only rewritten if it's actually a Nix store path (a
    # shebang already pointing outside the store, e.g. a real
    # "/usr/bin/env", is presumably a deliberate, genuinely host-provided
    # dependency, left untouched).
    mainBinAbs="${realDrv}/bin/${resolvedMainProgram}"
    mainBin="$appdir$mainBinAbs"
    firstAbs="$mainBinAbs"
    extraArg=""
    scriptInterp=$(sed -n '1{/^#!/{s/^#![[:space:]]*//;s/[[:space:]].*//;p}}' "$mainBin")
    if [ -n "$scriptInterp" ] && [ "''${scriptInterp#${builtins.storeDir}/}" != "$scriptInterp" ]; then
      firstAbs="$scriptInterp"
      extraArg="\$APPDIR$mainBinAbs"
    fi

    # Whatever ends up first in the exec chain (mainBin itself, or its
    # script interpreter) gets the same ELF-interpreter treatment as
    # before: real dynamically-linked ELF binaries have a PT_INTERP to
    # read back and invoke explicitly via ld.so + --library-path (see
    # the closure-copy loop above for why); a script or a static binary
    # don't, and patchelf just errors on those, so they fall through to
    # a plain exec.
    if interp=$(patchelf --print-interpreter "$appdir$firstAbs" 2>/dev/null); then
      loader="\$APPDIR$interp --library-path \"$libpath\""
    else
      loader=""
    fi

    cat > "$appdir/AppRun" <<APPRUN_EOF
    #!/bin/sh
    exec $loader "\$APPDIR$firstAbs" $extraArg "\$@"
    APPRUN_EOF
    chmod 755 "$appdir/AppRun"

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
