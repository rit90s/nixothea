# Builds the real .rpm via rpmbuild -- one combined package, same as
# aur/deb: every transitively-reachable node's own real build output is
# folded into the same payload tree as the root's, not split into
# separate interdependent .rpms.
{ pkgs, lib, realDrv, allPayloads, runtimeRpmPackages, description, license, group, architecture, vendor, targetInterpreter }:
let
  requiresLine = lib.concatMapStringsSep ", " (p: "${p.name} = ${p.evr}") runtimeRpmPackages;

  # AutoReqProv is off because rpmbuild's automatic dependency scanner
  # runs ldd/rpmdeps against the packaged binaries expecting a normal
  # system layout -- against Nix-produced binaries (Nix store RPATHs,
  # foreign extracted-.rpm libraries) it would either choke or fabricate
  # bogus Requires/Provides. Requires: is instead built entirely from
  # what resolver.nix already verified. debug_package/_build_id_links
  # are disabled since there's no source here for rpmbuild to generate a
  # debuginfo package from.
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

    %files
    /usr
  '');
in
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-rpm";
  version = realDrv.version;
  dontUnpack = true;
  # patchelf: retargets our own built binaries from Nix's dynamic linker
  # to the real target system's, and drops the Nix-store RPATH entries
  # bintools-wrapper added for buildInputs -- see the interpreter
  # comment above for why this isn't optional. Left untouched: the
  # extracted third-party .rpm payloads never enter this tree (only
  # allPayloads -- our own realDrv/nested-node outputs -- do), so
  # nothing here is foreign toolchain-built content.
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
