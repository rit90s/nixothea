# Fetches each package in entry.packages (by the url+sha256 resolve
# pinned -- a real, reproducible fixed-output fetch, no apt needed again),
# extracts them all with dpkg-deb into one merged tree, reproduces
# Debian's /lib->/usr/lib merge for packages that predate it (e.g. zlib1g
# ships real files directly under lib/, not usr/lib/), fixes up the
# absolute symlinks dpkg-deb preserves verbatim (which assume a real root
# filesystem) to point inside the merged output instead, and exposes
# top-level include/lib so Nix's own cc-wrapper auto-adds -I/-L for this
# buildInput exactly like it would for any normal nixpkgs library -- no
# custom setup-hook needed.
{ pkgs, lib, entry, multiarchTriplet }:
let
  fetched = map
    (p: pkgs.fetchurl { inherit (p) url sha256; name = "${p.name}.deb"; })
    entry.packages;
in
pkgs.stdenv.mkDerivation {
  pname = "${entry.name}-deb-extracted";
  version = (builtins.head entry.packages).version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.dpkg ];
  # Foreign, already-built Debian binaries -- stripping/patchelf-ing them
  # would risk breaking whatever ABI expectations Debian's own toolchain
  # baked in, for no benefit (nothing here needs to conform to Nix's own
  # binary hygiene, only to link correctly).
  dontFixup = true;
  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (f: "dpkg-deb -x ${f} $out") fetched}

    for d in lib lib32 lib64 bin sbin; do
      if [ -d "$out/$d" ] && [ ! -L "$out/$d" ]; then
        mkdir -p "$out/usr/$d"
        cp -a "$out/$d/." "$out/usr/$d/"
        rm -rf "$out/$d"
      fi
    done

    find $out -type l | while read -r link; do
      target=$(readlink "$link")
      case "$target" in
        /lib/*|/lib32/*|/lib64/*|/bin/*|/sbin/*) ln -sfn "$out/usr$target" "$link" ;;
        /usr/*) ln -sfn "$out$target" "$link" ;;
      esac
    done

    [ -d "$out/usr/include" ] && ln -s "$out/usr/include" "$out/include"
    [ -d "$out/usr/lib/${multiarchTriplet}" ] && ln -s "$out/usr/lib/${multiarchTriplet}" "$out/lib"
    runHook postBuild
  '';
  dontInstall = true;
  # Not string-coercible (a list of attrsets), so it has to be passthru
  # rather than a normal derivation attr -- read back by
  # deb-package.pkg.nix to build Depends:.
  passthru = { debPackages = entry.packages; };
}
