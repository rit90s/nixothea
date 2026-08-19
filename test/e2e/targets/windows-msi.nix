# End-to-end test of the `windowsMsi` target (targets/windows-msi/): real
# cross-compile (pkgsCross.mingwW64) against a real dependency (zlib,
# transparent pass-through -- same as windowsExe), a real WiX-format
# .msi built via `wixl` (msitools, a from-scratch Linux-native WiX
# compiler -- no Wine needed to *build*), then actually installed and run
# under a real Wine prefix via `wine msiexec`.
#
# `wineWow64Packages.stable`, not the deprecated `wineWowPackages` alias
# -- see windows-exe.nix's own comment for why (same underlying build,
# but the deprecated name resolves to a differently-derived, uncached
# path under this flake's pinned nixpkgs).
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;

  upgradeCode = "12345678-1234-1234-1234-123456789012";
  msiTarget = targets.windowsMsi { inherit upgradeCode; publisher = "Nixothea Tests"; };

  lockFile = builtins.toFile "windows-msi-lock.json" (builtins.toJSON {
    targets.m = { zlib = { name = "zlib"; }; };
  });

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildInputs = [ pkgs.zlib ];
      meta.description = "nixothea windowsMsi-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <zlib.h>
        int main(void) { printf("windowsMsi zlib %s\n", zlibVersion()); return 0; }
        EOF
        $CC hello.c -o hello.exe -I${pkgs.zlib}/include -L${pkgs.zlib}/lib -lz
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello.exe $out/bin/
      '';
    };

  built = (buildTarget { targets.m = msiTarget; inherit lockFile definition; }).m;

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
      targets.m = msiTarget;
      lockFile = builtins.toFile "windows-msi-lock-empty.json" (builtins.toJSON { targets = { }; });
      definition = ambiguousDefinition;
    }).m.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-windows-msi-structure"
      { msiOut = built; nativeBuildInputs = [ pkgs.msitools ]; }
      ''
        msi=$(ls "$msiOut"/*.msi)
        if [ -z "$msi" ]; then
          echo "FAIL: no .msi produced" >&2
          exit 1
        fi
        # An MSI is an OLE/CFB compound file -- real magic bytes, not just
        # "some file exists".
        magic=$(head -c8 "$msi" | od -An -tx1 | tr -d ' \n')
        if [ "$magic" != "d0cf11e0a1b11ae1" ]; then
          echo "FAIL: $msi is not an OLE compound file (bad magic: $magic)" >&2
          exit 1
        fi
        # A real read via msitools' own msiinfo -- confirms wixl produced
        # a genuinely well-formed MSI database, not just a file with the
        # right leading bytes.
        if ! msiinfo suminfo "$msi" | grep -qF 'hello'; then
          echo "FAIL: msiinfo suminfo didn't mention the package name" >&2
          msiinfo suminfo "$msi" >&2
          exit 1
        fi

        echo "nixothea-test-target-windows-msi-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-windows-msi-run";
    runtimeInputs = [ pkgs.wineWow64Packages.stable ];
    text = ''
      export WINEPREFIX
      WINEPREFIX="$(mktemp -d)"
      export WINEDEBUG=-all
      msi=$(ls ${built}/*.msi)
      # Wine maps the real Linux filesystem root to Z: by default -- no
      # separate winepath/copy step needed to hand msiexec a real path.
      wine msiexec /i "Z:$msi" /qn 'INSTALLDIR=C:\hello'
      actual=$(wine "C:\\hello\\hello.exe")
      echo "windowsMsi payload printed (inside a real Wine prefix): $actual"
      case "$actual" in
        "windowsMsi zlib "*) : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-windows-msi-run: passed"
    '';
  };
} // (
  if !ambiguousThrew then
    throw "nixothea e2e windowsMsi-target: expected a throw for ambiguous bin/ entries, none happened"
  else
    { }
)
