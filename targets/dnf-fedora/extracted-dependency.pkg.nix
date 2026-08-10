# Fetches each package in entry.packages (by the url+sha256 resolve
# pinned -- a real, reproducible fixed-output fetch, no dnf needed again)
# and extracts them all with rpm2cpio into one merged tree. Unlike deb,
# no /lib -> /usr/lib merge is needed: Fedora completed its usrmerge
# years ago, so every file in a modern Fedora rpm already lives under
# usr/. Also unlike deb, no symlink-target fixup is needed: Fedora
# packaging guidelines require relative symlinks (verified empirically --
# rpmlint would flag an absolute one), so nothing here points outside the
# extracted tree. Exposes top-level include/lib so Nix's own
# bintools-wrapper auto-adds -L for this buildInput exactly like it would
# for any normal nixpkgs library -- no custom setup-hook needed.
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
  # Foreign, already-built Fedora binaries -- stripping/patchelf-ing them
  # would risk breaking whatever ABI expectations Fedora's own toolchain
  # baked in, for no benefit.
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
  # Not string-coercible (a list of attrsets), so it has to be passthru
  # rather than a normal derivation attr -- read back by
  # rpm-package.pkg.nix to build Requires:.
  passthru = { rpmPackages = entry.packages; };
}
