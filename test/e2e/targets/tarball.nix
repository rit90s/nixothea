# End-to-end test of the `tarball` target (targets/tarball/): real
# closure-bundling build for two different compression settings, the
# produced archive actually extracted and its launcher actually run (a
# real full Nix closure, relocated, patchelf'd, extracted, and executed --
# no /nix/store visible other than what's bundled), plus tarball's two
# `mainProgram`-specific edge cases: ambiguous bin/ (shared with every
# target using autoDetectMainProgram, see test/e2e/main-program.nix) and
# tarball's own extra constraint, mainProgram can't be "nix".
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  emptyLock = builtins.toFile "tarball-lock.json" (builtins.toJSON { targets = { }; });

  # `zlib` here is the *outer*, real nixpkgs zlib (this test file's own
  # `pkgs` argument, captured under a different name so it isn't shadowed
  # by `definition`'s own `pkgs` parameter below) -- tarball never exposes
  # any declared dependency (`nativeDerivationFactory` always throws,
  # `resolve` always emits an empty section), so linking against a real
  # library here has to bypass the restricted per-target `pkgs` entirely,
  # the same way appimage.nix's own e2e test does.
  zlib = pkgs.zlib;

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("tarball zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello -I ${zlib.dev or zlib}/include -L ${zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  mkRunCheck = name: compression:
    let
      built = (buildTarget {
        targets.tb = targets.tarball { inherit compression; };
        lockFile = emptyLock;
        inherit definition;
      }).tb;
      tarFlag = {
        gzip = "z"; xz = "J"; zstd = "--zstd"; none = "";
      }.${compression};
    in
    pkgs.runCommand "nixothea-test-target-tarball-run-${name}"
      { tarballOut = built; nativeBuildInputs = [ pkgs.gnutar pkgs.zstd ]; }
      ''
        archive=$(ls "$tarballOut"/*)
        mkdir extracted
        tar ${if compression == "zstd" then "--use-compress-program=unzstd" else "-${tarFlag}"} -xf "$archive" -C extracted
        pkgdir=$(ls -d extracted/*/)
        launcher="''${pkgdir}$(ls "$pkgdir" | grep -v '^nix$')"
        if [ ! -x "$launcher" ]; then
          echo "FAIL: launcher $launcher missing or not executable" >&2
          ls -la "$pkgdir" >&2
          exit 1
        fi
        actual=$("$launcher")
        case "$actual" in
          "tarball zlib "*) : ;;
          *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
        esac
        echo "nixothea-test-target-tarball-run-${name}: passed ($actual)" > $out
      '';

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
    (buildTarget { targets.tb = targets.tarball { }; lockFile = emptyLock; definition = ambiguousDefinition; }).tb.drvPath
    true)).success;

  # mainProgram explicitly set to "nix" -- collides with the bundled
  # closure's own nix/ directory at the top level of the extracted tree.
  nixCollisionThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.tb = targets.tarball { };
      lockFile = emptyLock;
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildPhase = "true";
        installPhase = ''
          mkdir -p $out/bin
          printf '#!/bin/sh\n' > $out/bin/nix
          chmod +x $out/bin/nix
        '';
      };
    }).tb.drvPath
    true)).success;
in
{
  checks = {
    run-gzip = mkRunCheck "gzip" "gzip";
    run-zstd = mkRunCheck "zstd" "zstd";
  };
} // (
  if !ambiguousThrew then
    throw "nixothea e2e tarball-target: expected a throw for ambiguous bin/ entries, none happened"
  else if !nixCollisionThrew then
    throw "nixothea e2e tarball-target: expected a throw for mainProgram = \"nix\", none happened"
  else
    { }
)
