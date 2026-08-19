# End-to-end test of the `homebrew` target (targets/homebrew/): real
# Formula generation, checked structurally -- same reasoning as
# aur.nix's own header comment for why real `brew install` execution is
# out of scope by design (this target never compiles real software
# itself; a real Homebrew tap install runs the Formula's `install do`
# block later, on the user's own machine). What's checked for real: the
# generated Formula is real, syntactically valid Ruby (`ruby -c`, a
# genuine parse), and its content -- class-name sanitization (including
# the leading-digit "X" prefix, dashes/underscores/dots), url/sha256/
# version/revision, license (single vs `any_of:` for multiple),
# depends_on, and collectDeps' real nested-node merge into the `install`
# block's heredocs -- is exactly what builder.nix is supposed to produce.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  emptyLock = builtins.toFile "homebrew-lock.json" (builtins.toJSON { targets = { }; });

  homebrewTarget = targets.homebrew { revision = 2; };

  # homebrew's `nativeDerivationFactory` is pure metadata (no real
  # derivation -- see builder.nix's own header comment), so a *declared
  # dependency* (what becomes `depends_on`) is a genuinely different
  # thing from a nested `pkgs.mkDerivation` node like `shared` below
  # (what becomes an extra build()/install() step) -- this lock entry
  # exercises the former.
  lockFile = builtins.toFile "homebrew-lock.json" (builtins.toJSON {
    targets.h = { zlib = { name = "zlib"; versionConstraint = ">=1.3"; }; };
  });

  shared = { pkgs }:
    pkgs.mkDerivation {
      pname = "shared"; version = "1.0";
      dontUnpack = true;
      buildPhase = "echo shared-step";
      installPhase = "echo shared-install-step";
    };

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "7-zip-extra.tool"; version = "3.1";
      dontUnpack = true;
      buildInputs = [ (shared { inherit pkgs; }) pkgs.zlib ];
      meta = {
        description = "nixothea homebrew-target e2e fixture";
        homepage = "https://example.invalid/hello";
        license = [ "mit" "apache-2.0" ];
      };
      homebrewSource = "https://example.invalid/hello-3.1.tar.gz";
      homebrewSourceSha256 = "0000000000000000000000000000000000000000000000000000000000bb";
      buildPhase = ''
        echo root-build-step
      '';
      installPhase = ''
        echo root-install-step
      '';
    };

  built = (buildTarget { targets.h = homebrewTarget; inherit lockFile definition; }).h;

  missingSourceThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.h = homebrewTarget;
      lockFile = emptyLock;
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "bad"; version = "1"; dontUnpack = true;
        buildPhase = "true"; installPhase = "true";
      };
    }).h.drvPath
    true)).success;

  missingShaThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.h = homebrewTarget;
      lockFile = emptyLock;
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "bad2"; version = "1"; dontUnpack = true;
        homebrewSource = "https://example.invalid/bad2.tar.gz"; # no sha256
        buildPhase = "true"; installPhase = "true";
      };
    }).h.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-homebrew-structure"
      { homebrewOut = built; nativeBuildInputs = [ pkgs.ruby ]; }
      ''
        formula=$(ls "$homebrewOut"/*.rb)
        if [ -z "$formula" ]; then
          echo "FAIL: no Formula produced" >&2
          exit 1
        fi

        # A real Ruby parse -- not just grepping for expected substrings.
        if ! ruby -c "$formula" >/dev/null; then
          echo "FAIL: Formula is not syntactically valid Ruby" >&2
          cat "$formula" >&2
          exit 1
        fi

        check() {
          if ! grep -qF "$1" "$formula"; then
            echo "FAIL: Formula missing expected line: $1" >&2
            cat "$formula" >&2
            exit 1
          fi
        }
        # pname "7-zip-extra.tool" -> segments [7,zip,extra,tool] (split on
        # "-", with "_"/"." folded to "-" first) -> capitalized+joined ->
        # leading digit gets the "X" prefix (builder.nix's className).
        check 'class X7ZipExtraTool < Formula'
        check "desc 'nixothea homebrew-target e2e fixture'"
        check "homepage 'https://example.invalid/hello'"
        check "url 'https://example.invalid/hello-3.1.tar.gz'"
        check "sha256 '0000000000000000000000000000000000000000000000000000000000bb'"
        check "version '3.1'"
        check 'revision 2'
        check "license any_of: ['mit', 'apache-2.0']"
        check "depends_on 'zlib'"
        check 'shared-step'
        check 'shared-install-step'
        check 'root-build-step'
        check 'root-install-step'

        # collectDeps' merge order inside the install block: the nested
        # node's own build step precedes the root's own.
        install_start=$(grep -n 'def install' "$formula" | cut -d: -f1)
        shared_line=$(grep -n 'shared-step' "$formula" | cut -d: -f1)
        root_line=$(grep -n 'root-build-step' "$formula" | cut -d: -f1)
        if [ "$shared_line" -lt "$install_start" ] || [ "$shared_line" -gt "$root_line" ]; then
          echo "FAIL: shared-step must appear inside install, before root-build-step" >&2
          cat "$formula" >&2
          exit 1
        fi

        echo "nixothea-test-target-homebrew-structure: passed" > $out
      '';
  };
} // (
  if !missingSourceThrew then
    throw "nixothea e2e homebrew-target: expected a throw when homebrewSource is unset, none happened"
  else if !missingShaThrew then
    throw "nixothea e2e homebrew-target: expected a throw when homebrewSourceSha256 is unset, none happened"
  else
    { }
)
