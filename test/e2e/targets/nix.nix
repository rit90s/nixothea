# End-to-end test of the `nix` target (targets/nix.nix): transparent
# passthrough -- `nativeDerivationFactory` is a real nixpkgs attribute
# lookup, `mkDerivation` returns `realDrv` unchanged regardless of role.
# Real compile, real link against a real resolved dependency (zlib) and a
# real nested node (a small helper "library" node, exercising the
# `role = "dependency"` passthrough path for a *node*, not a resolved
# dependency), the produced binary actually run and its output checked.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  nixTarget = targets.nix { };
  buildTarget = import ../../../lib/build.nix;

  lockFile = builtins.toFile "nix-target-lock.json" (builtins.toJSON {
    targets.nix = { zlib = { name = "zlib"; }; };
  });

  definition = { pkgs }:
    let
      greeter = pkgs.mkDerivation {
        pname = "greeter"; version = "1.0";
        dontUnpack = true;
        buildPhase = ''
          cat > greeter.c <<'EOF'
          const char *greeting(void) { return "hi from greeter"; }
          EOF
          $CC -c greeter.c -o greeter.o
          ar rcs libgreeter.a greeter.o
        '';
        installPhase = ''
          mkdir -p $out/lib $out/include
          cp libgreeter.a $out/lib/
          echo 'const char *greeting(void);' > $out/include/greeter.h
        '';
      };
    in
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildInputs = [ greeter pkgs.zlib ];
      meta.description = "nixothea nix-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        #include "greeter.h"
        int main(void) {
          printf("%s, zlib %s\n", greeting(), zlibVersion());
          return 0;
        }
        EOF
        $CC hello.c -I ${greeter}/include -L ${greeter}/lib -lgreeter -lz -o hello
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = buildTarget { targets.nix = nixTarget; inherit lockFile definition; };

  unknownAttrThrows = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.nix = nixTarget;
      lockFile = builtins.toFile "nix-target-lock-bad.json" (builtins.toJSON {
        targets.nix = { doesNotExist = { name = "this-attr-does-not-exist-in-nixpkgs"; }; };
      });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "p"; version = "1"; dontUnpack = true;
        buildInputs = [ pkgs.doesNotExist ];
        buildPhase = "true"; installPhase = "mkdir -p $out";
      };
    }).nix.drvPath
    true)).success;
in
{
  checks = {
    run = pkgs.runCommand "nixothea-test-target-nix-run" { helloOut = built.nix; } ''
      if [ ! -x "$helloOut/bin/hello" ]; then
        echo "FAIL: $helloOut/bin/hello missing or not executable" >&2
        exit 1
      fi
      actual=$("$helloOut/bin/hello")
      case "$actual" in
        "hi from greeter, zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-nix-run: passed ($actual)" > $out
    '';
  };
} // (
  if !unknownAttrThrows then
    throw "nixothea e2e nix-target: expected a throw for an unknown nixpkgs attribute name, none happened"
  else
    { }
)
