# Builds the real .rpm via rpmbuild -- one combined package, same as
# aur/deb.
{ pkgs, lib, realDrv, allPayloads, runtimeRpmPackages, description, license, group, architecture, vendor, targetInterpreter }:
let
  requiresLine = lib.concatMapStringsSep ", " (p: "${p.name} = ${p.evr}") runtimeRpmPackages;

  specFile = pkgs.writeText "${realDrv.pname}.spec" (''
    Name: ${realDrv.pname}
    Version: ${realDrv.version}
    Release: 1
    Summary: ${description}
    License: ${license}
    Group: ${group}
    BuildArch: ${architecture}
    AutoReqProv: no
  '' + lib.optionalString (vendor != null) "Vendor: ${vendor}\n"
  + lib.optionalString (runtimeRpmPackages != [ ]) "Requires: ${requiresLine}\n"
  + ''

    %global debug_package %{nil}
    %global _build_id_links none

    %description
    ${description}

    %install
    mkdir -p %{buildroot}/usr
  '' + lib.concatMapStringsSep "\n" (p: ''
    cp -a --no-preserve=ownership ${p}/. "%{buildroot}/usr/"
    chmod -R u+w "%{buildroot}/usr"
  '') allPayloads
  + ''

    find %{buildroot}/usr -type f | while read -r f; do
      if patchelf --print-rpath "$f" >/dev/null 2>&1; then
        patchelf --remove-rpath "$f" || true
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter "${targetInterpreter}" "$f"
        fi
      fi
    done

    # Lists only real files/symlinks, never directories -- see
    # dnf-fedora/rpm-package.pkg.nix's own comment for why: claiming a
    # directory in %files makes rpm compare its mode against every other
    # package that also owns it, and a real base `filesystem` package
    # routinely hardens some of them differently than a plain `mkdir -p`
    # here produces, causing a real "file ... conflicts" install failure.
    find %{buildroot}/usr -mindepth 1 \( -type f -o -type l \) -printf '/usr/%%P\n' > %{_builddir}/files.list

    %files -f %{_builddir}/files.list
  '');
in
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-rpm";
  version = realDrv.version;
  dontUnpack = true;
  # patchelf: retargets our own built binaries from Nix's dynamic linker
  # to the real target system's, and drops the Nix-store RPATH entries
  # bintools-wrapper added for buildInputs.
  nativeBuildInputs = [ pkgs.rpm pkgs.patchelf ];
  buildPhase = ''
    runHook preBuild
    mkdir -p rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} rpmdb rpmtmp buildroot
    HOME=$PWD rpmbuild \
      --define "_topdir $PWD/rpmbuild" \
      --define "_dbpath $PWD/rpmdb" \
      --define "_tmppath $PWD/rpmtmp" \
      --buildroot "$PWD/buildroot" \
      -bb ${specFile}
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    find rpmbuild/RPMS -name '*.rpm' -exec cp {} $out/ \;
    runHook postInstall
  '';
}
