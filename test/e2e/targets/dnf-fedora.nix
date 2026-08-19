# End-to-end test of the `dnfFedora` target (targets/dnf-fedora/): real
# .rpm build (interpreter retargeted from Nix's own dynamic linker to
# Fedora's real absolute path, a real dependency fetched from the real
# Fedora archive and extracted during the build so the real compile can
# actually link against it) plus structural validation of the generated
# spec-derived package, then the produced .rpm actually installed and run
# inside a real `fedora:44` userspace.
#
# Fedora's own zlib runtime package is named `zlib-ng-compat` (a real,
# ABI-compatible reimplementation, not plain "zlib" -- confirmed by hand
# while designing this test: Fedora 44's repo has no `zlib`/`zlib-devel`
# package at all, only `zlib-ng*`), which is exactly the naming pitfall
# resolver.nix's own header comment warns name-prefix heuristics can't
# handle -- this test's dependency is deliberately that one, not a
# same-named-everywhere convenience pick.
#
# The dependency's lock entry below is hand-crafted with a real,
# currently-valid url/sha256 (obtained by hand, once, by actually running
# this exact target's own resolver against the real Fedora 44 archive
# while designing this test) -- same reasoning as deb.nix's own header
# comment.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;

  releasever = "44";
  repos = [{
    id = "fedora";
    baseurl = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/";
  }];
  fedTarget = targets.dnfFedora { inherit repos releasever; };

  lockFile = builtins.toFile "dnf-fedora-lock.json" (builtins.toJSON {
    targets.f = {
      zlib = {
        name = "zlib-ng-compat-devel";
        packages = [
          {
            name = "zlib-ng-compat-devel";
            evr = "2.3.3-3.fc44";
            arch = "x86_64";
            url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/Packages/z/zlib-ng-compat-devel-2.3.3-3.fc44.x86_64.rpm";
            sha256 = "66ce7228ae8befaad9282647a5c6a6f649cd20d7702dfa07869d653d7c4589c0";
            kind = "devel";
          }
          {
            name = "zlib-ng-compat";
            evr = "2.3.3-3.fc44";
            arch = "x86_64";
            url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/Packages/z/zlib-ng-compat-2.3.3-3.fc44.x86_64.rpm";
            sha256 = "53ee3cd7082b1a34e4901f13079b1840648113c809effb5b78e7725235a7d939";
            kind = "runtime";
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
      meta.description = "nixothea dnfFedora-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("dnfFedora zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${pkgs.zlib}/include -L ${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.f = fedTarget; inherit lockFile definition; }).f;

  # `architecture` feeds builder.nix's `archLibDirs`/`interpreters` lookups,
  # forced while building rpm-package.pkg.nix's buildPhase regardless of
  # whether any dependency was declared -- same reasoning as deb.nix's own
  # `unsupportedArchThrew`.
  unsupportedArchThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.f = targets.dnfFedora { inherit repos releasever; architecture = "riscv64"; };
      lockFile = builtins.toFile "dnf-fedora-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildPhase = "true"; installPhase = "mkdir -p $out/bin; printf '#!/bin/sh\\n' > $out/bin/p; chmod +x $out/bin/p";
      };
    }).f.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-dnf-fedora-structure"
      { rpmOut = built; nativeBuildInputs = [ pkgs.rpm pkgs.patchelf ]; }
      ''
        rpm=$(ls "$rpmOut"/*.rpm)
        if [ -z "$rpm" ]; then
          echo "FAIL: no .rpm produced" >&2
          exit 1
        fi

        # --dbpath: the sandbox has no writable /var/lib/rpm for rpm's
        # default database, and `-qp` (query a plain file) doesn't need a
        # real one -- pointing it at an empty scratch dir sidesteps the
        # "cannot open Packages database" error.
        export RPMDB="$TMPDIR/rpmdb"
        rpmq() { rpm --dbpath "$RPMDB" -qp "$@"; }
        if [ "$(rpmq --qf '%{ARCH}' "$rpm")" != "x86_64" ]; then
          echo "FAIL: Arch field wrong" >&2
          exit 1
        fi
        requires=$(rpmq --requires "$rpm")
        if ! echo "$requires" | grep -qF 'zlib-ng-compat = 2.3.3-3.fc44'; then
          echo "FAIL: Requires: missing zlib-ng-compat" >&2
          echo "$requires" >&2
          exit 1
        fi
        if echo "$requires" | grep -qF 'zlib-ng-compat-devel'; then
          echo "FAIL: Requires: must not include the -devel package" >&2
          echo "$requires" >&2
          exit 1
        fi

        mkdir extracted
        (cd extracted && rpm2cpio "$rpm" | ${pkgs.cpio}/bin/cpio -idm --quiet)
        bin="extracted/usr/bin/hello"
        if [ ! -f "$bin" ]; then
          echo "FAIL: $bin missing from the extracted payload" >&2
          find extracted >&2
          exit 1
        fi
        interp=$(patchelf --print-interpreter "$bin")
        if [ "$interp" != "/lib64/ld-linux-x86-64.so.2" ]; then
          echo "FAIL: interpreter not retargeted to Fedora's real path, got: $interp" >&2
          exit 1
        fi

        echo "nixothea-test-target-dnf-fedora-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-dnf-fedora-run";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-$(mktemp -d)}"
      rpm=$(ls ${built}/*.rpm)
      actual=$(podman run --rm -v "$rpm:/pkg.rpm:ro" docker.io/library/fedora:44 bash -c \
        'dnf install -y -q /pkg.rpm >/dev/null && /usr/bin/hello')
      echo "dnfFedora payload printed (inside a real fedora:44 container): $actual"
      case "$actual" in
        "dnfFedora zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-dnf-fedora-run: passed"
    '';
  };
} // (
  if !unsupportedArchThrew then
    throw "nixothea e2e dnfFedora-target: expected a throw for an unsupported architecture, none happened"
  else
    { }
)
