# End-to-end test of the `dnfRhel` target (targets/dnf-rhel/): real .rpm
# build against CentOS Stream 10 (the freely-accessible concrete distro
# this target uses -- see targets/dnf-rhel/default.nix's own header
# comment), same overall shape as dnf-fedora.nix -- see that module's
# comments for what's shared (interpreter retarget, %files -f generated
# file list to avoid a real directory-mode conflict with the base
# `filesystem` package, etc.).
#
# The dependency's lock entry below is hand-crafted with a real,
# currently-valid url/sha256 (obtained by hand, once, by actually running
# this exact target's own resolver against the real CentOS Stream 10
# BaseOS/AppStream archives while designing this test). Confirmed while
# doing that real run that CentOS Stream also names its zlib runtime
# `zlib-ng-compat` (same as Fedora, unlike openSUSE's plain `libz1`) --
# split across BaseOS (runtime) and AppStream (the -devel package), which
# is exactly why this target's own `repos` needs both.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;

  releasever = "10-stream";
  repos = [
    { id = "baseos"; baseurl = "https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/"; }
    { id = "appstream"; baseurl = "https://mirror.stream.centos.org/10-stream/AppStream/x86_64/os/"; }
  ];
  rhelTarget = targets.dnfRhel { inherit repos releasever; };

  lockFile = builtins.toFile "dnf-rhel-lock.json" (builtins.toJSON {
    targets.r = {
      zlib = {
        name = "zlib-ng-compat-devel";
        packages = [
          {
            name = "zlib-ng-compat-devel";
            evr = "2.2.3-3.el10";
            arch = "x86_64";
            url = "https://mirror.stream.centos.org/10-stream/AppStream/x86_64/os/Packages/zlib-ng-compat-devel-2.2.3-3.el10.x86_64.rpm";
            sha256 = "8a5a306e08b301ec0b3928967a9f29f582c0b64e7eb78152b1d1d2e41ec495d1";
            kind = "devel";
          }
          {
            name = "zlib-ng-compat";
            evr = "2.2.3-3.el10";
            arch = "x86_64";
            url = "https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/Packages/zlib-ng-compat-2.2.3-3.el10.x86_64.rpm";
            sha256 = "8fe3c2d5203810828fa3e4a5d84ae53172ffd27f4f0eec9d192b42b187795c09";
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
      meta.description = "nixothea dnfRhel-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("dnfRhel zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${pkgs.zlib}/include -L ${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.r = rhelTarget; inherit lockFile definition; }).r;

  # Same `unsupportedArchThrew` shape as dnf-fedora.nix's own -- a
  # separate builder.nix with its own `interpreters` lookup, so worth
  # confirming independently rather than assuming Fedora's coverage
  # implies this one.
  unsupportedArchThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.r = targets.dnfRhel { inherit repos releasever; architecture = "riscv64"; };
      lockFile = builtins.toFile "dnf-rhel-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildPhase = "true"; installPhase = "mkdir -p $out/bin; printf '#!/bin/sh\\n' > $out/bin/p; chmod +x $out/bin/p";
      };
    }).r.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-dnf-rhel-structure"
      { rpmOut = built; nativeBuildInputs = [ pkgs.rpm pkgs.cpio pkgs.patchelf ]; }
      ''
        rpm=$(ls "$rpmOut"/*.rpm)
        if [ -z "$rpm" ]; then
          echo "FAIL: no .rpm produced" >&2
          exit 1
        fi

        export RPMDB="$TMPDIR/rpmdb"
        rpmq() { rpm --dbpath "$RPMDB" -qp "$@"; }
        if [ "$(rpmq --qf '%{ARCH}' "$rpm")" != "x86_64" ]; then
          echo "FAIL: Arch field wrong" >&2
          exit 1
        fi
        requires=$(rpmq --requires "$rpm")
        if ! echo "$requires" | grep -qF 'zlib-ng-compat = 2.2.3-3.el10'; then
          echo "FAIL: Requires: missing zlib-ng-compat" >&2
          echo "$requires" >&2
          exit 1
        fi
        if echo "$requires" | grep -qF 'zlib-ng-compat-devel'; then
          echo "FAIL: Requires: must not include the -devel package" >&2
          echo "$requires" >&2
          exit 1
        fi
        # %files was generated as an explicit leaf file list (see
        # dnf-fedora/rpm-package.pkg.nix's comment) -- confirm this
        # package doesn't itself claim ownership of any directory, which
        # is exactly what caused a real install conflict against Fedora's
        # own hardened /usr/bin before that fix.
        if rpmq -l "$rpm" | grep -qE '^/usr(/bin)?$'; then
          echo "FAIL: package still claims ownership of a bare directory" >&2
          rpmq -l "$rpm" >&2
          exit 1
        fi

        mkdir extracted
        (cd extracted && rpm2cpio "$rpm" | cpio -idm --quiet)
        bin="extracted/usr/bin/hello"
        if [ ! -f "$bin" ]; then
          echo "FAIL: $bin missing from the extracted payload" >&2
          find extracted >&2
          exit 1
        fi
        interp=$(patchelf --print-interpreter "$bin")
        if [ "$interp" != "/lib64/ld-linux-x86-64.so.2" ]; then
          echo "FAIL: interpreter not retargeted to CentOS Stream's real path, got: $interp" >&2
          exit 1
        fi

        echo "nixothea-test-target-dnf-rhel-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-dnf-rhel-run";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-$(mktemp -d)}"
      rpm=$(ls ${built}/*.rpm)
      actual=$(podman run --rm -v "$rpm:/pkg.rpm:ro" quay.io/centos/centos:stream10 bash -c \
        'dnf install -y -q /pkg.rpm >/dev/null && /usr/bin/hello')
      echo "dnfRhel payload printed (inside a real centos:stream10 container): $actual"
      case "$actual" in
        "dnfRhel zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-dnf-rhel-run: passed"
    '';
  };
} // (
  if !unsupportedArchThrew then
    throw "nixothea e2e dnfRhel-target: expected a throw for an unsupported architecture, none happened"
  else
    { }
)
