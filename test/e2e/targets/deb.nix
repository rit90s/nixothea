# End-to-end test of the `deb` target (targets/deb/): real .deb build
# (interpreter retargeted from Nix's own dynamic linker to Debian's real
# absolute path, a real dependency -- zlib1g-dev/zlib1g -- fetched from
# the real Debian archive and extracted during the build so the real
# compile can actually link against it) plus structural validation of the
# generated control file, then the produced .deb actually installed and
# run inside a real `debian:bookworm` userspace.
#
# Unlike `snap`, `deb` doesn't bundle its runtime dependency into the
# payload -- it expects the target system's own package manager to
# satisfy `Depends:` (the normal Debian packaging model), so real
# execution needs a real `dpkg`/`apt` environment, not just a matching
# absolute interpreter path. `apps.test-target-deb-run` gets one for real
# via podman, the same way docker.nix/snap.nix's own apps do.
#
# The dependency's lock entry below is hand-crafted with a real,
# currently-valid url/sha256 (obtained by hand, once, by actually running
# this exact target's own resolver against the real Debian bookworm
# archive while designing this test) rather than produced by running
# `resolve` inside this test -- same reasoning as snap.nix's own header
# comment: `fetchurl` is a fixed-output derivation (fine even inside a
# network-less sandboxed check), but resolving against a live apt-get
# isn't. Debian bookworm is a frozen stable release, so unlike a rolling
# archive this exact version is expected to stay downloadable for the
# release's lifetime.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  mkResolver = import ../../../lib/resolver.nix;

  repos = [{
    url = "https://deb.debian.org/debian";
    suite = "bookworm";
    components = [ "main" ];
  }];

  debTarget = targets.deb { inherit repos; };

  lockFile = builtins.toFile "deb-lock.json" (builtins.toJSON {
    targets.d = {
      zlib = {
        name = "zlib1g-dev";
        packages = [
          {
            name = "zlib1g-dev";
            version = "1:1.2.13.dfsg-1";
            url = "https://deb.debian.org/debian/pool/main/z/zlib/zlib1g-dev_1.2.13.dfsg-1_amd64.deb";
            sha256 = "f9ce531f60cbd5df37996af9370e0171be96902a17ec2bdbd8d62038c354094f";
            section = "libdevel";
          }
          {
            name = "zlib1g";
            version = "1:1.2.13.dfsg-1";
            url = "https://deb.debian.org/debian/pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb";
            sha256 = "d7dd1d1411fedf27f5e27650a6eff20ef294077b568f4c8c5e51466dc7c08ce4";
            section = "libs";
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
      meta.description = "nixothea deb-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("deb zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${pkgs.zlib}/include -L ${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.d = debTarget; inherit lockFile definition; }).d;

  # `architecture` feeds `builder.nix`'s `multiarchTriplets`/`interpreters`
  # lookups, forced while building deb-package.pkg.nix's buildPhase (every
  # payload binary gets patchelf'd to the target interpreter regardless of
  # whether any dependency was declared) -- so a plain "root"-role build
  # with no dependencies at all still forces the throw. Not `deepSeq`ing
  # the whole target/derivation value: it carries a `.pkgs` field (the
  # entire real nixpkgs), and deepSeq forcing that recurses into all of
  # nixpkgs -- `.drvPath` (a plain string) is what's forced instead.
  unsupportedArchThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.d = targets.deb { inherit repos; architecture = "sparc64"; };
      lockFile = builtins.toFile "deb-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildPhase = "true"; installPhase = "mkdir -p $out/bin; printf '#!/bin/sh\\n' > $out/bin/p; chmod +x $out/bin/p";
      };
    }).d.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-deb-structure"
      { debOut = built; nativeBuildInputs = [ pkgs.dpkg pkgs.patchelf ]; }
      ''
        deb=$(ls "$debOut"/*.deb)
        if [ -z "$deb" ]; then
          echo "FAIL: no .deb produced" >&2
          exit 1
        fi

        control=$(dpkg-deb -f "$deb")
        if ! echo "$control" | grep -qE '^Architecture: amd64$'; then
          echo "FAIL: Architecture field wrong" >&2
          echo "$control" >&2
          exit 1
        fi
        # Depends: must list the runtime library (zlib1g) but never the
        # -dev package (section libdevel, filtered by builder.nix's
        # runtimeDebPackages -- headers/static libs are a build-time-only
        # concern, a real installed package shouldn't pull them in).
        depends=$(echo "$control" | grep '^Depends:' || true)
        if ! echo "$depends" | grep -qF 'zlib1g (= 1:1.2.13.dfsg-1)'; then
          echo "FAIL: Depends: missing zlib1g" >&2
          echo "$depends" >&2
          exit 1
        fi
        if echo "$depends" | grep -qF 'zlib1g-dev'; then
          echo "FAIL: Depends: must not include the -dev package" >&2
          echo "$depends" >&2
          exit 1
        fi

        mkdir extracted
        dpkg-deb -x "$deb" extracted
        bin="extracted/usr/bin/hello"
        if [ ! -f "$bin" ]; then
          echo "FAIL: $bin missing from the extracted payload" >&2
          find extracted >&2
          exit 1
        fi
        interp=$(patchelf --print-interpreter "$bin")
        if [ "$interp" != "/lib64/ld-linux-x86-64.so.2" ]; then
          echo "FAIL: interpreter not retargeted to Debian's real path, got: $interp" >&2
          exit 1
        fi
        if [ -n "$(patchelf --print-rpath "$bin")" ]; then
          echo "FAIL: RPATH not stripped, would shadow the target system's real search path" >&2
          exit 1
        fi

        echo "nixothea-test-target-deb-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-deb-run";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-$(mktemp -d)}"
      deb=$(ls ${built}/*.deb)
      # APT::Sandbox::User=root: apt normally drops privileges to the
      # unprivileged _apt user for its network fetch, which needs a real
      # subuid/subgid range mapped into the container -- not present for a
      # plain rootless podman container with only a single mapped uid.
      # Confirmed by hand while designing this that omitting this flag
      # fails with "setgroups: Operation not permitted" before apt can
      # even reach the network.
      actual=$(podman run --rm -v "$deb:/pkg.deb:ro" docker.io/library/debian:bookworm bash -c \
        'apt-get -o APT::Sandbox::User=root update -qq >/dev/null && apt-get -o APT::Sandbox::User=root install -y -qq zlib1g=1:1.2.13.dfsg-1 >/dev/null && dpkg -i /pkg.deb >/dev/null && /usr/bin/hello')
      echo "deb payload printed (inside a real debian:bookworm container): $actual"
      case "$actual" in
        "deb zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-deb-run: passed"
    '';
  };
} // (
  if !unsupportedArchThrew then
    throw "nixothea e2e deb-target: expected a throw for an unsupported architecture, none happened"
  else
    { }
)
