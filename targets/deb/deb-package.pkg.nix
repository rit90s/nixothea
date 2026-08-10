# Builds the real .deb via dpkg-deb -- one combined package, same as
# aur: every transitively-reachable node's own real build output is
# folded into the same payload tree as the root's, not split into
# separate interdependent .debs.
{ pkgs, lib, realDrv, allPayloads, runtimeDebPackages, maintainer, section, priority, architecture, description, targetInterpreter }:
let
  dependsLine = lib.concatMapStringsSep ", " (p: "${p.name} (= ${p.version})") runtimeDebPackages;

  controlFile = pkgs.writeText "control" (''
    Package: ${realDrv.pname}
    Version: ${realDrv.version}
    Section: ${section}
    Priority: ${priority}
    Architecture: ${architecture}
  '' + lib.optionalString (maintainer != null) "Maintainer: ${maintainer}\n"
  + lib.optionalString (runtimeDebPackages != [ ]) "Depends: ${dependsLine}\n"
  + "Description: ${description}\n");
in
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-deb";
  version = realDrv.version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.dpkg pkgs.patchelf ];
  buildPhase = ''
    runHook preBuild
    root=pkgroot
    mkdir -p "$root/DEBIAN" "$root/usr"
    ${lib.concatMapStringsSep "\n" (p: ''
      cp -a --no-preserve=ownership ${p}/. "$root/usr/"
      chmod -R u+w "$root/usr"
    '') allPayloads}

    # Retargets our own built binaries from Nix's dynamic linker to the
    # real target system's (see builder.nix's `interpreters` map for why
    # this isn't optional), and drops the Nix-store RPATH entries
    # bintools-wrapper added for buildInputs -- without this, the loader
    # falls through to the *target*'s normal search path, which is
    # exactly where Depends: ensures the runtime library actually gets
    # installed. Left untouched: the extracted third-party .deb payloads
    # never enter this tree (only allPayloads -- our own realDrv/
    # nested-node outputs -- do), so nothing here is foreign
    # Debian-toolchain-built content.
    find "$root/usr" -type f | while read -r f; do
      if patchelf --print-rpath "$f" >/dev/null 2>&1; then
        patchelf --remove-rpath "$f" || true
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter "${targetInterpreter}" "$f"
        fi
      fi
    done

    cp ${controlFile} "$root/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$root" "${realDrv.pname}_${realDrv.version}_${architecture}.deb"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp ./*.deb $out/
    runHook postInstall
  '';
}
