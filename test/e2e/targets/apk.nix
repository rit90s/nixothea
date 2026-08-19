# End-to-end test of the `apk` target (targets/apk/): real .apk build
# (interpreter retargeted from Nix's own glibc dynamic linker to Alpine's
# real musl one, a real dependency -- zlib-dev -- fetched from the real
# Alpine archive and extracted during the build so the real compile can
# actually link against a genuinely musl-linked `pkgsMusl.zlib`) plus
# structural validation of the generated .PKGINFO, then the produced .apk
# actually installed and run inside a real `alpine:3.20` userspace.
#
# Like `deb`, `apk` doesn't bundle its runtime dependency into the
# payload -- it expects the target system's own `apk` to satisfy
# `depend =` from its configured repos, so real execution needs a real
# Alpine `apk`/musl environment, not just a matching interpreter path.
#
# The dependency's lock entry below is hand-crafted with a real,
# currently-valid url/sha256 (obtained by hand, once, by actually running
# this exact target's own resolver against the real Alpine v3.20/main
# archive while designing this test) -- same reasoning as deb.nix's own
# header comment. Confirmed while doing that real run that `zlib-dev`'s
# real dependency closure also pulls in `pkgconf` (a real Alpine
# packaging convention -- a -dev package `depend`s on pkgconf so
# `pkg-config --libs` works for consumers) -- excluded from the final
# .apk's own `depend =` lines the same way the -dev package itself is
# (see builder.nix's `excludeNames`), verified structurally below.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;

  repos = [ "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" ];
  apkTarget = targets.apk { inherit repos; };

  lockFile = builtins.toFile "apk-lock.json" (builtins.toJSON {
    targets.a = {
      zlib = {
        name = "zlib-dev";
        packages = [
          {
            name = "pkgconf";
            version = "2.2.0-r0";
            url = "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/pkgconf-2.2.0-r0.apk";
            sha256 = "4699dc8b3d8ccbb4522b66a236cd36c0dbdeb54adce6df27139d976eb7d1905d";
          }
          {
            name = "zlib";
            version = "1.3.2-r0";
            url = "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/zlib-1.3.2-r0.apk";
            sha256 = "39c506b74e5bf4b693179d0aefd10b161278063261ffdaa8fe704d075c64429b";
          }
          {
            name = "zlib-dev";
            version = "1.3.2-r0";
            url = "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/zlib-dev-1.3.2-r0.apk";
            sha256 = "7fd9ec4aeac0719e5568062b9e4545e6b1c315ac477b37dad16ab4e5e2463729";
          }
        ];
      };
    };
  });

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildInputs = [ pkgs.zlib ];
      meta.description = "nixothea apk-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("apk zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${pkgs.zlib}/include -L ${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.a = apkTarget; inherit lockFile definition; }).a;

  # `architecture` feeds builder.nix's `interpreters` lookup, forced while
  # building apk-package.pkg.nix's buildPhase regardless of whether any
  # dependency was declared -- same reasoning as deb.nix's own
  # `unsupportedArchThrew`. Not `deepSeq`ing the whole target/derivation
  # value for the same reason as every other throws-check in this suite:
  # it carries a `.pkgs` field (the entire real pkgsMusl), and deepSeq
  # forcing that recurses into all of it.
  unsupportedArchThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.a = targets.apk { inherit repos; architecture = "riscv64"; };
      lockFile = builtins.toFile "apk-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildPhase = "true"; installPhase = "mkdir -p $out/bin; printf '#!/bin/sh\\n' > $out/bin/p; chmod +x $out/bin/p";
      };
    }).a.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-apk-structure"
      { apkOut = built; nativeBuildInputs = [ pkgs.gnutar pkgs.patchelf ]; }
      ''
        apk=$(ls "$apkOut"/*.apk)
        if [ -z "$apk" ]; then
          echo "FAIL: no .apk produced" >&2
          exit 1
        fi

        mkdir extracted
        # A real .apk is just concatenated gzip members -- plain tar
        # already handles a multi-member gzip stream transparently (see
        # extracted-dependency.pkg.nix's own header comment).
        tar -xzf "$apk" -C extracted

        pkginfo="extracted/.PKGINFO"
        if [ ! -f "$pkginfo" ]; then
          echo "FAIL: no .PKGINFO in the built .apk" >&2
          exit 1
        fi
        if ! grep -qE '^arch = x86_64$' "$pkginfo"; then
          echo "FAIL: arch field wrong" >&2
          cat "$pkginfo" >&2
          exit 1
        fi
        # depend = must list the runtime library (zlib, by bare name=version,
        # not a soname) but never the -dev package or pkgconf (see this
        # file's header comment for why pkgconf rides along in the real
        # resolve but has to be excluded here).
        if ! grep -qF 'depend = zlib=1.3.2-r0' "$pkginfo"; then
          echo "FAIL: depend = missing zlib" >&2
          cat "$pkginfo" >&2
          exit 1
        fi
        if grep -qE '^depend = (zlib-dev|pkgconf)' "$pkginfo"; then
          echo "FAIL: depend = must not include zlib-dev or pkgconf" >&2
          cat "$pkginfo" >&2
          exit 1
        fi

        bin="extracted/usr/bin/hello"
        if [ ! -f "$bin" ]; then
          echo "FAIL: $bin missing from the extracted payload" >&2
          find extracted >&2
          exit 1
        fi
        interp=$(patchelf --print-interpreter "$bin")
        if [ "$interp" != "/lib/ld-musl-x86_64.so.1" ]; then
          echo "FAIL: interpreter not retargeted to Alpine's real musl path, got: $interp" >&2
          exit 1
        fi

        echo "nixothea-test-target-apk-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-apk-run";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-$(mktemp -d)}"
      apk=$(ls ${built}/*.apk)
      actual=$(podman run --rm -v "$apk:/pkg.apk:ro" docker.io/library/alpine:3.20 sh -c \
        'apk add --no-cache --allow-untrusted /pkg.apk >/dev/null && /usr/bin/hello')
      echo "apk payload printed (inside a real alpine:3.20 container): $actual"
      case "$actual" in
        "apk zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-apk-run: passed"
    '';
  };
} // (
  if !unsupportedArchThrew then
    throw "nixothea e2e apk-target: expected a throw for an unsupported architecture, none happened"
  else
    { }
)
