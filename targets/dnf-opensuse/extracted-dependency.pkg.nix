# Same as the other dnf-based targets: no /lib -> /usr/lib merge or
# symlink fixup needed (verified empirically -- openSUSE Leap is
# merged-usr with relative symlinks too).
{ pkgs, lib, entry, libDir }:
let
  fetched = map
    (p: pkgs.fetchurl { inherit (p) url sha256; name = "${p.name}.rpm"; })
    entry.packages;
in
pkgs.stdenv.mkDerivation {
  pname = "${entry.name}-rpm-extracted";
  version = (builtins.head entry.packages).evr;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.rpm pkgs.cpio ];
  dontFixup = true;
  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (f: "(cd $out && rpm2cpio ${f} | cpio -idm --quiet)") fetched}
    [ -d "$out/usr/include" ] && ln -s "$out/usr/include" "$out/include"
    [ -d "$out/usr/${libDir}" ] && ln -s "$out/usr/${libDir}" "$out/lib"
    runHook postBuild
  '';
  dontInstall = true;
  passthru = { rpmPackages = entry.packages; };
}
