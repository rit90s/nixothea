# Fetches each package in entry.packages (by the url+sha256 resolve
# pinned -- a real, reproducible fixed-output fetch, no apk needed again)
# and extracts them all into one merged tree. A real .apk is just a
# concatenation of gzip members (signature, control, data -- see
# apk-package.pkg.nix's header comment); plain `tar` already handles
# multi-member gzip streams transparently, so this doesn't need any
# apk-specific tool, just excludes the dot-prefixed control-metadata
# entries (.PKGINFO, .SIGN.*) that every real Alpine package carries
# alongside its real data files. Real Alpine ships some shared libs
# directly under bare lib/ rather than usr/lib/ (unlike a usr-merged
# distro) -- consolidated into usr/lib here, then symlinked back, the
# same merge deb.nix's extracted-dependency does for pre-usrmerge debs,
# so Nix's own cc-wrapper auto-adds -I$out/include -L$out/lib for this
# buildInput exactly like it would for any normal nixpkgs library.
{ pkgs, lib, entry }:
let
  fetched = map
    (p: pkgs.fetchurl { inherit (p) url sha256; name = "${p.name}.apk"; })
    entry.packages;
in
pkgs.stdenv.mkDerivation {
  pname = "${entry.name}-apk-extracted";
  version = (builtins.head entry.packages).version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.gnutar ];
  # Foreign, already-built Alpine binaries -- stripping/patchelf-ing them
  # would risk breaking whatever ABI expectations Alpine's own toolchain
  # baked in, for no benefit.
  dontFixup = true;
  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    ${lib.concatMapStringsSep "\n"
      (f: "tar --no-same-owner --exclude='.PKGINFO' --exclude='.SIGN.*' -xzf ${f} -C $out 2>/dev/null")
      fetched}

    if [ -d "$out/lib" ] && [ ! -L "$out/lib" ]; then
      mkdir -p "$out/usr/lib"
      cp -a "$out/lib/." "$out/usr/lib/"
      rm -rf "$out/lib"
    fi

    find $out -type l | while read -r link; do
      target=$(readlink "$link")
      case "$target" in
        /lib/*) ln -sfn "$out/usr/lib/''${target#/lib/}" "$link" ;;
        /usr/*) ln -sfn "$out$target" "$link" ;;
      esac
    done

    [ -d "$out/usr/include" ] && ln -s "$out/usr/include" "$out/include"
    [ -d "$out/usr/lib" ] && ln -s "$out/usr/lib" "$out/lib"
    runHook postBuild
  '';
  dontInstall = true;
  # Not string-coercible (a list of attrsets), so it has to be passthru
  # rather than a normal derivation attr -- read back by
  # apk-package.pkg.nix to build the `depend =` lines.
  passthru = { apkPackages = entry.packages; };
}
