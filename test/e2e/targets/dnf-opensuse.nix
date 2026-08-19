# End-to-end test of the `dnfOpensuse` target (targets/dnf-opensuse/):
# real .rpm build against openSUSE Leap 15.6, same overall shape as
# dnf-fedora.nix/dnf-rhel.nix -- see those modules' comments for what's
# shared. Unlike Fedora/RHEL, openSUSE names its zlib packages plainly
# (`zlib-devel`/`libz1`, no `-ng-compat` reimplementation) -- confirmed
# by hand while designing this test, real evidence that the runtime
# package name really does vary per distro family the way this whole
# per-target suite has been demonstrating (deb1g/zlib-ng-compat/libz1/
# zlib-dev, four different real names for what's conceptually "zlib"
# across deb/dnfFedora-RHEL/dnfOpensuse/apk).
#
# openSUSE's real container image ships `zypper`, not `dnf`/`dnf5` (this
# target still uses dnf5 to *resolve*, per targets/dnf-opensuse/default.nix's
# own header comment on why -- openSUSE's repos are createrepo-format
# compatible), so `apps.run` installs the built .rpm with a real `zypper`
# instead.
#
# The dependency's lock entry below is hand-crafted with a real,
# currently-valid url/sha256 (obtained by hand, once, by actually running
# this exact target's own resolver against the real openSUSE Leap 15.6
# archive while designing this test).
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;

  releasever = "15.6";
  repos = [{ id = "oss"; baseurl = "https://download.opensuse.org/distribution/leap/15.6/repo/oss/"; }];
  susTarget = targets.dnfOpensuse { inherit repos releasever; };

  lockFile = builtins.toFile "dnf-opensuse-lock.json" (builtins.toJSON {
    targets.s = {
      zlib = {
        name = "zlib-devel";
        packages = [
          {
            name = "zlib-devel";
            evr = "1.2.13-150500.4.3.1";
            arch = "x86_64";
            url = "https://download.opensuse.org/distribution/leap/15.6/repo/oss/x86_64/zlib-devel-1.2.13-150500.4.3.1.x86_64.rpm";
            sha256 = "16b0c66f6384d2ed18894441075a928d263897e8fb1c0c496f9ee41f3a1c2411";
            kind = "devel";
          }
          {
            name = "libz1";
            evr = "1.2.13-150500.4.3.1";
            arch = "x86_64";
            url = "https://download.opensuse.org/distribution/leap/15.6/repo/oss/x86_64/libz1-1.2.13-150500.4.3.1.x86_64.rpm";
            sha256 = "1f273509bd76f485a289e23791a3d9c5fec7b982fe91f59000d191d40375840d";
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
      meta.description = "nixothea dnfOpensuse-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("dnfOpensuse zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${pkgs.zlib}/include -L ${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.s = susTarget; inherit lockFile definition; }).s;

  unsupportedArchThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.s = targets.dnfOpensuse { inherit repos releasever; architecture = "riscv64"; };
      lockFile = builtins.toFile "dnf-opensuse-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildPhase = "true"; installPhase = "mkdir -p $out/bin; printf '#!/bin/sh\\n' > $out/bin/p; chmod +x $out/bin/p";
      };
    }).s.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-dnf-opensuse-structure"
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
        if ! echo "$requires" | grep -qF 'libz1 = 1.2.13-150500.4.3.1'; then
          echo "FAIL: Requires: missing libz1" >&2
          echo "$requires" >&2
          exit 1
        fi
        if echo "$requires" | grep -qF 'zlib-devel'; then
          echo "FAIL: Requires: must not include the -devel package" >&2
          echo "$requires" >&2
          exit 1
        fi
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
          echo "FAIL: interpreter not retargeted to openSUSE's real path, got: $interp" >&2
          exit 1
        fi

        echo "nixothea-test-target-dnf-opensuse-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-dnf-opensuse-run";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-$(mktemp -d)}"
      rpm=$(ls ${built}/*.rpm)
      # --force-resolution: the real `opensuse/leap:15.6` image already
      # ships a newer libz1 point-release than the distribution/oss tree
      # this package's exact-version Requires: was resolved against
      # (confirmed by hand while designing this: Leap's own official
      # image bakes in Update-repo packages even for a nominally frozen
      # release, unlike Fedora/CentOS Stream's release trees) -- without
      # it zypper just presents an interactive downgrade-or-abort choice.
      # --no-gpg-checks: same reasoning as apk's --allow-untrusted/deb's
      # unauthenticated install -- this target deliberately produces an
      # unsigned .rpm (see rpm-package.pkg.nix's own header comment).
      actual=$(podman run --rm -v "$rpm:/pkg.rpm:ro" docker.io/opensuse/leap:15.6 bash -c \
        'zypper --non-interactive --no-gpg-checks install -y --force-resolution /pkg.rpm >/dev/null && /usr/bin/hello')
      echo "dnfOpensuse payload printed (inside a real opensuse/leap:15.6 container): $actual"
      case "$actual" in
        "dnfOpensuse zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-dnf-opensuse-run: passed"
    '';
  };
} // (
  if !unsupportedArchThrew then
    throw "nixothea e2e dnfOpensuse-target: expected a throw for an unsupported architecture, none happened"
  else
    { }
)
