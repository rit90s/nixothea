# End-to-end test of the `appimage` target (targets/appimage/): real
# squashfs+runtime-stub build, the produced .AppImage actually executed
# (via --appimage-extract-and-run, so no /dev/fuse dependency -- this
# needs to work the same inside a network/device-less Nix build sandbox
# as on a real desktop), including real dynamic linking against a real
# nixpkgs closure (zlib) it never explicitly declared -- appimage doesn't
# support declared dependencies at all (nativeDerivationFactory always
# throws), so this exercises the target's actual design point: it bundles
# whatever's *really* in `realDrv`'s Nix closure, discovered structurally
# via `closureInfo`, not anything hand-declared.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  emptyLock = builtins.toFile "appimage-lock.json" (builtins.toJSON { targets = { }; });

  appimageTarget = targets.appimage { };

  # The *outer*, real nixpkgs zlib (this test file's own `pkgs` argument,
  # captured under a different name so it isn't shadowed by `definition`'s
  # own `pkgs` parameter below) -- not routed through the target's
  # restricted `definition`-scoped `pkgs` (appimage exposes none, by
  # design). Still ends up a real link-time and runtime dependency of
  # `realDrv`, which is exactly what `closureInfo` is supposed to pick up
  # on its own.
  zlib = pkgs.zlib;

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("appimage zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${zlib.dev or zlib}/include -L ${zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.appimage = appimageTarget; lockFile = emptyLock; inherit definition; }).appimage;

  ambiguousDefinition = { pkgs }:
    pkgs.mkDerivation {
      pname = "ambiguous"; version = "1.0";
      dontUnpack = true;
      buildPhase = "true";
      installPhase = ''
        mkdir -p $out/bin
        printf '#!/bin/sh\n' > $out/bin/a
        printf '#!/bin/sh\n' > $out/bin/b
        chmod +x $out/bin/a $out/bin/b
      '';
    };
  ambiguousThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget { targets.appimage = appimageTarget; lockFile = emptyLock; definition = ambiguousDefinition; }).appimage.drvPath
    true)).success;

  updateInfoTarget = targets.appimage { updateInformation = "zsync|https://example.com/hello.AppImage.zsync"; };
  updateInfoThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget { targets.appimage = updateInfoTarget; lockFile = emptyLock; inherit definition; }).appimage.drvPath
    true)).success;
in
{
  checks = {
    run = pkgs.runCommand "nixothea-test-target-appimage-run"
      { appimageOut = built; nativeBuildInputs = [ ]; }
      ''
        img=$(ls "$appimageOut"/*.AppImage)
        if [ -z "$img" ]; then
          echo "FAIL: no .AppImage produced" >&2
          exit 1
        fi
        # Already executable as built (appimage-package.pkg.nix's own
        # installPhase chmods it before copying to $out) -- the Nix store
        # is read-only, so re-chmod'ing the store path itself would fail.
        if [ ! -x "$img" ]; then
          echo "FAIL: $img is not executable" >&2
          exit 1
        fi
        export HOME="$TMPDIR"
        actual=$("$img" --appimage-extract-and-run)
        case "$actual" in
          "appimage zlib "*) : ;;
          *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
        esac
        echo "nixothea-test-target-appimage-run: passed ($actual)" > $out
      '';
  };
} // (
  if !ambiguousThrew then
    throw "nixothea e2e appimage-target: expected a throw for ambiguous bin/ entries, none happened"
  else if !updateInfoThrew then
    throw "nixothea e2e appimage-target: expected a throw for updateInformation (not yet implemented), none happened"
  else
    { }
)
