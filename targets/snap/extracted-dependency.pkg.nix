# Real fetch+dpkg-deb-extract for one resolved dependency's full closure --
# same mechanism as deb's own nativeDerivationFactory (see there for the
# full rationale of each step). Serves double duty: used as a Nix
# buildInput so the caller's own code can genuinely compile/link against
# it (headers + linkable .so, via the top-level include/lib symlinks
# Nix's cc-wrapper picks up automatically), *and* its usr/ subtree gets
# bundled wholesale straight into the final snap's own payload (see
# payload.pkg.nix) -- unlike deb, which only ever needs it for the former.
{ pkgs, lib, entry, multiarchTriplet }:
let
  fetched = map
    (p: pkgs.fetchurl { inherit (p) url sha256; name = "${p.name}.deb"; })
    entry.packages;
in
pkgs.stdenv.mkDerivation {
  pname = "${entry.name}-snap-extracted";
  version = (builtins.head entry.packages).version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.dpkg ];
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
}
