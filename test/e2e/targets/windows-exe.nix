# End-to-end test of the `windowsExe` target (targets/windows-exe/): real
# cross-compile (pkgsCross.mingwW64) against a real dependency (zlib,
# transparent pass-through to the cross pkgs set -- see this target's own
# header comment for why there's no resolve step doing real work), a real
# NSIS installer built via makensis, then actually installed and run
# under a real Wine prefix.
#
# `wineWow64Packages.stable`, not plain `wine64`: confirmed by hand while
# designing this that a real makensis-built installer's own stub is a
# 32-bit PE regardless of the payload's architecture, so running it needs
# WoW64 support (`wine64` alone fails immediately trying to load
# `syswow64\ntdll.dll`) -- `wineWow64Packages` bundles both. Deliberately
# not `wineWowPackages` (the older, deprecated alias for the same thing):
# confirmed by hand that it resolves to a differently-derived build that
# Hydra hasn't cached under this flake's pinned nixpkgs revision, forcing
# a from-scratch Wine compile -- `wineWow64Packages` is cached.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;

  exeTarget = targets.windowsExe { publisher = "Nixothea Tests"; };

  lockFile = builtins.toFile "windows-exe-lock.json" (builtins.toJSON {
    targets.w = { zlib = { name = "zlib"; }; };
  });

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildInputs = [ pkgs.zlib ];
      meta.description = "nixothea windowsExe-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("windowsExe zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello.exe -I${pkgs.zlib}/include -L${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello.exe $out/bin/
      '';
    };

  built = (buildTarget { targets.w = exeTarget; inherit lockFile definition; }).w;

  ambiguousDefinition = { pkgs }:
    pkgs.mkDerivation {
      pname = "ambiguous"; version = "1.0";
      dontUnpack = true;
      buildPhase = ''
        cat > a.c <<'EOF'
        int main(void) { return 0; }
        EOF
        $CC a.c -o a.exe
        $CC a.c -o b.exe
      '';
      installPhase = "mkdir -p $out/bin; cp a.exe b.exe $out/bin/";
    };
  ambiguousThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.w = exeTarget;
      lockFile = builtins.toFile "windows-exe-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = ambiguousDefinition;
    }).w.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-windows-exe-structure"
      { exeOut = built; }
      ''
        installer=$(ls "$exeOut"/*.exe)
        if [ -z "$installer" ]; then
          echo "FAIL: no installer .exe produced" >&2
          exit 1
        fi
        # A real NSIS-built PE binary -- confirm the DOS/PE header, not
        # just that some file exists.
        if [ "$(head -c2 "$installer")" != "MZ" ]; then
          echo "FAIL: $installer is not a PE executable (no MZ header)" >&2
          exit 1
        fi

        echo "nixothea-test-target-windows-exe-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-windows-exe-run";
    runtimeInputs = [ pkgs.wineWow64Packages.stable ];
    text = ''
      export WINEPREFIX
      WINEPREFIX="$(mktemp -d)"
      export WINEDEBUG=-all
      installer=$(ls ${built}/*.exe)
      wine "$installer" /S /D=C:\\hello
      actual=$(wine "C:\\hello\\hello.exe")
      echo "windowsExe payload printed (inside a real Wine prefix): $actual"
      case "$actual" in
        "windowsExe zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-windows-exe-run: passed"
    '';
  };
} // (
  if !ambiguousThrew then
    throw "nixothea e2e windowsExe-target: expected a throw for ambiguous bin/ entries, none happened"
  else
    { }
)
