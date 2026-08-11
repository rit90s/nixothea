# Builds the real .apk by hand, the same way `abuild`'s own `create_apks`
# does internally (verified by reading abuild's source and reproducing
# its exact sequence): a real Alpine package is just two (or, for a
# signed/published one, three) concatenated gzip members -- an optional
# signature, a small "control" member (.PKGINFO + any install scripts),
# and a "data" member (the real installed files) -- readable as one
# combined tar stream because `abuild-tar --cut` strips the end-of-
# archive trailer from every member but the last before concatenating.
# This produces an unsigned .apk (installable via `apk add --allow-
# untrusted`), same reasoning as deb.nix/rpm-package.pkg.nix producing
# unsigned artifacts: real package signing needs a real private key,
# which doesn't belong baked into a reproducible Nix build.
{ pkgs, lib, realDrv, allPayloads, runtimeApkPackages, maintainer, pkgrel, architecture, targetInterpreter, description, license }:
let
  licenseName = l: if builtins.isString l then l else (l.spdxId or l.shortName or null);
  licenseNames = l:
    if l == null then [ ]
    else if builtins.isList l then lib.filter (x: x != null) (map licenseName l)
    else lib.filter (x: x != null) [ (licenseName l) ];
  licenseLine = let ls = licenseNames license; in if ls == [ ] then "unknown" else lib.concatStringsSep " AND " ls;

  pkgver = "${realDrv.version}-r${toString pkgrel}";
  apkName = "${realDrv.pname}-${pkgver}.apk";

  dependLines = [ "so:libc.musl-${architecture}.so.1" ]
    ++ map (p: "${p.name}=${p.version}") runtimeApkPackages;
in
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-apk";
  version = realDrv.version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.abuild pkgs.patchelf ];
  buildPhase = ''
    runHook preBuild
    dataroot=dataroot
    mkdir -p "$dataroot/usr"
    ${lib.concatMapStringsSep "\n" (p: ''
      cp -a --no-preserve=ownership ${p}/. "$dataroot/usr/"
      chmod -R u+w "$dataroot/usr"
    '') allPayloads}

    # Same reasoning as deb.nix's own patchelf pass: retargets our own
    # built binaries from Nix's dynamic linker to the real target
    # system's musl (see builder.nix's `interpreters` map), and drops the
    # Nix-store RPATH bintools-wrapper added for buildInputs -- without
    # this the binary can't even start on a real Alpine machine,
    # independent of whether `depend =` is satisfied.
    find "$dataroot" -type f | while read -r f; do
      if patchelf --print-rpath "$f" >/dev/null 2>&1; then
        patchelf --remove-rpath "$f" || true
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter "${targetInterpreter}" "$f"
        fi
      fi
    done

    size=$(cd "$dataroot" && find . -mindepth 1 -type f -exec stat -c '%d:%i %s' -- {} + | \
      awk '!x[$1]++ {s+=$2} END {print s+0}')

    cat > .PKGINFO <<EOF
    pkgname = ${realDrv.pname}
    pkgver = ${pkgver}
    pkgdesc = ${description}
    url = https://example.invalid
    builddate = ''${SOURCE_DATE_EPOCH:-0}
    packager = nixothea
    size = $size
    arch = ${architecture}
    origin = ${realDrv.pname}
    license = ${licenseLine}
    EOF
    ${lib.concatMapStringsSep "\n" (d: "echo 'depend = ${d}' >> .PKGINFO") dependLines}

    # data.tar.gz: the same apk_tar/abuild-tar --hash pipeline abuild
    # itself uses (verified by reproducing it against a real curl.apk and
    # installing the result with a real `apk add --allow-untrusted`) --
    # abuild-tar --hash embeds a per-file checksum apk uses for install-
    # time integrity verification. No "./" path prefixes: real Alpine
    # packages don't use them either (verified against a real curl.apk),
    # and it's one less thing that could confuse apk's own tar reader.
    #
    # abuild-tar --hash reliably exits 1 even on success (verified: still
    # 1 with a single file, still 1 with several -- not a file-count exit
    # code, just a real quirk of the tool), which would otherwise abort
    # the whole build here under stdenv's `set -o pipefail`; disabled
    # around just this pipeline, not the rest of the script.
    set +o pipefail
    ( cd "$dataroot" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z | \
        tar --format=posix --pax-option=exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0 \
          --no-recursion --null -f - -c -T - --owner=0 --group=0 --numeric-owner \
        --mtime="@''${SOURCE_DATE_EPOCH:-0}" ) \
      | abuild-tar --hash | gzip -n -9 > data.tar.gz
    set -o pipefail
    [ -s data.tar.gz ] || { echo "nixothea apk target: data.tar.gz ended up empty" >&2; exit 1; }
    datahash=$(sha256sum data.tar.gz | cut -d' ' -f1)
    echo "datahash = $datahash" >> .PKGINFO

    # control.tar.gz: same pipeline, over just .PKGINFO -- `--cut` drops
    # the end-of-archive trailer so it concatenates seamlessly with
    # data.tar.gz below into one continuous tar stream. `--cut` doesn't
    # share `--hash`'s exit-1-on-success quirk, but disabled the same way
    # for consistency/safety.
    set +o pipefail
    printf '.PKGINFO\0' \
      | tar --format=posix --pax-option=exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0 \
          --no-recursion --null -f - -c -T - --owner=0 --group=0 --numeric-owner \
          --mtime="@''${SOURCE_DATE_EPOCH:-0}" \
      | abuild-tar --cut | gzip -n -9 > control.tar.gz
    set -o pipefail
    [ -s control.tar.gz ] || { echo "nixothea apk target: control.tar.gz ended up empty" >&2; exit 1; }

    cat control.tar.gz data.tar.gz > "${apkName}"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp "${apkName}" $out/
    runHook postInstall
  '';
}
