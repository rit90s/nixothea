# End-to-end test of the `snap` target (targets/snap/): real payload
# build (interpreter retargeted from Nix's own dynamic linker to the base
# snap's real absolute path, a real dependency -- zlib1g -- fetched from a
# real Ubuntu archive and bundled straight into the payload) plus
# structural validation of the generated snapcraft.yaml.
#
# The dependency's lock entry below is hand-crafted with a real,
# currently-valid url/sha256 (obtained by hand, once, by actually running
# this exact target's own resolver against the real Ubuntu noble archive
# while designing this test) rather than produced by running `resolve`
# inside this test -- `fetchurl` is a fixed-output derivation, so
# *fetching* it is fine even inside Nix's network-less build sandbox (the
# output hash is pre-declared and verified), but *resolving* (turning a
# bare package name into a concrete url/hash via a live apt-get) is
# inherently impure and can't run in a sandboxed check at all -- same
# reasoning as test/e2e/pipeline.nix's own hand-crafted lock file.
#
# Actually *running* the produced payload needs a real base-snap-shaped
# Ubuntu userspace at the real absolute paths the patched interpreter
# points at (e.g. /lib64/ld-linux-x86-64.so.2) -- nothing like that exists
# in this sandbox or on this host. `apps.test-target-snap-run` gets one
# for real instead, the same way test/e2e/targets/docker.nix's app gets a
# real container engine: a real `ubuntu:noble` container (noble is core24's
# real underlying suite, see targets/snap/default.nix's `baseSuites`) via
# podman, with the payload bind-mounted where a real snapd would mount a
# real snap -- confirmed by hand while designing this that a Nix-built,
# patchelf'd binary genuinely runs there, including genuinely linking
# against the bundled (not the container's own) libz.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  mkResolver = import ../../../lib/resolver.nix;

  snapTarget = targets.snap { };

  lockFile = builtins.toFile "snap-lock.json" (builtins.toJSON {
    targets.s = {
      zlib = {
        # zlib1g-dev (headers, needed to actually compile against it) plus
        # its own real Depends: zlib1g (the runtime .so) -- both real
        # entries obtained by hand by actually running this exact
        # resolver against the real noble archive while designing this
        # test, same reasoning as the header comment above.
        name = "zlib1g-dev";
        packages = [
          {
            name = "zlib1g-dev";
            version = "1:1.3.dfsg-3.1ubuntu2.1";
            url = "http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g-dev_1.3.dfsg-3.1ubuntu2.1_amd64.deb";
            sha256 = "023cbe9dbf0af87f10e54e342c67571874e412b9950d89c6cd7b010be2e67c3c";
            section = "libdevel";
          }
          {
            name = "zlib1g";
            version = "1:1.3.dfsg-3.1ubuntu2.1";
            url = "http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.1_amd64.deb";
            sha256 = "7074b6a2f6367a10d280c00a1cb02e74277709180bab4f2491a2f355ab2d6c20";
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
      meta.description = "nixothea snap-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("snap zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${pkgs.zlib}/include -L ${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.s = snapTarget; inherit lockFile definition; }).s;

  # `base` is validated in default.nix's own `let suite = baseSuites.${base}
  # or throw ...`, which only actually gets forced once something that
  # depends on `suite` is forced (it feeds `sourcesList`, used by
  # `resolve`) -- merely constructing the target value doesn't touch it.
  # Not `deepSeq`ing the target/derivation value directly either way: it
  # carries a `.pkgs` field (the *entire* real nixpkgs), and deepSeq
  # forcing that recurses into all of nixpkgs -- `.drvPath` (a plain
  # string) is what every other throws-check here forces instead.
  unsupportedBaseThrew = !(builtins.tryEval (builtins.deepSeq
    (mkResolver {
      dependencies = { };
      targets.s = targets.snap { base = "core16"; };
    }).drvPath
    true)).success;

  unsupportedArchThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.s = targets.snap { architecture = "riscv64"; };
      lockFile = builtins.toFile "snap-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildPhase = "true"; installPhase = "mkdir -p $out/bin; printf '#!/bin/sh\\n' > $out/bin/p; chmod +x $out/bin/p";
      };
    }).s.drvPath
    true)).success;

  # Sanitization is pure Nix logic (see builder.nix's `sanitizeSnapName`)
  # -- a weird pname (uppercase, leading digit, runs of invalid chars)
  # gets folded into a valid Snap Store name without needing a real build.
  weirdName = (buildTarget {
    targets.s = targets.snap { };
    lockFile = builtins.toFile "snap-lock-empty2.json" (builtins.toJSON { targets = { }; });
    definition = { pkgs }: pkgs.mkDerivation {
      pname = "3D_Viewer!!"; version = "1"; dontUnpack = true;
      buildPhase = "true"; installPhase = "mkdir -p $out/bin; printf '#!/bin/sh\\n' > $out/bin/v; chmod +x $out/bin/v";
    };
  }).s;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-snap-structure"
      { snapOut = built; nativeBuildInputs = [ pkgs.jq pkgs.patchelf ]; }
      ''
        yaml="$snapOut/snap/snapcraft.yaml"
        if [ ! -f "$yaml" ]; then
          echo "FAIL: no snap/snapcraft.yaml produced" >&2
          exit 1
        fi
        # snapcraft.yaml is written in JSON syntax (a valid YAML subset).
        if [ "$(jq -r '.base' "$yaml")" != "core24" ]; then echo "FAIL: base" >&2; exit 1; fi
        if [ "$(jq -r '.confinement' "$yaml")" != "strict" ]; then echo "FAIL: confinement" >&2; exit 1; fi
        if [ "$(jq -r '.apps.hello.command' "$yaml")" != "bin/hello" ]; then echo "FAIL: apps.hello.command" >&2; exit 1; fi

        bin="$snapOut/payload/bin/hello"
        if [ ! -x "$bin" ]; then
          echo "FAIL: $bin missing or not executable" >&2
          exit 1
        fi
        interp=$(patchelf --print-interpreter "$bin")
        if [ "$interp" != "/lib64/ld-linux-x86-64.so.2" ]; then
          echo "FAIL: interpreter not retargeted to the base snap's real path, got: $interp" >&2
          exit 1
        fi

        if ! ls "$snapOut"/payload/usr/lib/x86_64-linux-gnu/libz.so* > /dev/null 2>&1; then
          echo "FAIL: bundled zlib1g runtime library missing from the payload" >&2
          find "$snapOut/payload/usr" >&2
          exit 1
        fi

        echo "nixothea-test-target-snap-structure: passed" > $out
      '';

    edge-cases = pkgs.runCommand "nixothea-test-target-snap-edge-cases"
      { weirdOut = weirdName; nativeBuildInputs = [ pkgs.jq ]; }
      ''
        name=$(jq -r '.name' "$weirdOut/snap/snapcraft.yaml")
        case "$name" in
          [a-z]*) : ;;
          *) echo "FAIL: sanitized snap name '$name' doesn't start with a lowercase letter" >&2; exit 1 ;;
        esac
        if echo "$name" | grep -qE '[^a-z0-9-]'; then
          echo "FAIL: sanitized snap name '$name' contains invalid characters" >&2
          exit 1
        fi
        echo "nixothea-test-target-snap-edge-cases: passed (sanitized to '$name')" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-snap-run";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-$(mktemp -d)}"
      actual=$(podman run --rm -v "${built}/payload:/snap/hello/current:ro" docker.io/library/ubuntu:noble \
        env LD_LIBRARY_PATH=/snap/hello/current/usr/lib/x86_64-linux-gnu \
        /snap/hello/current/bin/hello)
      echo "snap payload printed (inside a real ubuntu:noble container): $actual"
      case "$actual" in
        "snap zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-snap-run: passed"
    '';
  };
} // (
  if !unsupportedBaseThrew then
    throw "nixothea e2e snap-target: expected a throw for an unsupported base, none happened"
  else if !unsupportedArchThrew then
    throw "nixothea e2e snap-target: expected a throw for an unsupported architecture, none happened"
  else
    { }
)
