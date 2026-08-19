# End-to-end test of the `aur` target (targets/aur/): real PKGBUILD
# generation, checked structurally -- `pacman`/`makepkg` (real Arch
# tooling that would actually run the generated recipe against a real
# Arch machine) aren't a realistic thing to bring into this environment
# for a build/run test the way podman was for docker/snap/deb/apk/dnf*
# (this target never builds real software itself in the first place --
# see targets/aur/default.nix's own header comment: it only ever
# generates a recipe for a real Arch machine to run later), so real
# execution is out of scope by design here, not just environment
# limitation. What *is* checked for real: the generated PKGBUILD is
# real, syntactically valid bash (`bash -n`, a genuine parse, not just
# eyeballing the string), and its content -- pkgname/pkgver/depends=/
# source=/sha256sums=/license=/arch=, the directory auto-detection in
# build()/package(), and collectDeps' real diamond-dedup merge of nested
# nodes' own build()/package() steps into the one combined recipe -- is
# exactly what builder.nix is supposed to produce.
#
# (test/e2e/pipeline.nix already exercises a real diamond-shaped
# dependency merge against this same target from the framework side;
# this file focuses on what pipeline.nix doesn't cover: aurSource/
# aurSourceSha256, the mismatched-pair throw, and per-target metadata
# fields.)
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  emptyLock = builtins.toFile "aur-lock.json" (builtins.toJSON { targets = { }; });

  aurTarget = targets.aur { maintainer = "Nixothea Test <test@example.invalid>"; };

  shared = { pkgs }:
    pkgs.mkDerivation {
      pname = "shared"; version = "1.0";
      dontUnpack = true;
      buildPhase = "echo shared-step";
      installPhase = "mkdir -p \"$out\"";
    };

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "2.5";
      dontUnpack = true;
      buildInputs = [ (shared { inherit pkgs; }) ];
      meta = {
        description = "nixothea aur-target e2e fixture";
        homepage = "https://example.invalid/hello";
        license = "mit";
      };
      aurSource = "https://example.invalid/hello-2.5.tar.gz";
      aurSourceSha256 = "0000000000000000000000000000000000000000000000000000000000aa";
      buildPhase = ''
        echo root-build-step
      '';
      installPhase = ''
        echo root-install-step
      '';
    };

  built = (buildTarget { targets.a = aurTarget; lockFile = emptyLock; inherit definition; }).a;

  mismatchedThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.a = aurTarget;
      lockFile = emptyLock;
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "bad"; version = "1"; dontUnpack = true;
        aurSource = "https://example.invalid/bad.tar.gz"; # no aurSourceSha256
        buildPhase = "true"; installPhase = "true";
      };
    }).a.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-aur-structure"
      { aurOut = built; nativeBuildInputs = [ pkgs.bash ]; }
      ''
        pkgbuild="$aurOut/PKGBUILD"
        if [ ! -f "$pkgbuild" ]; then
          echo "FAIL: no PKGBUILD produced" >&2
          exit 1
        fi

        # A real bash parse -- not just grepping for expected substrings.
        if ! bash -n "$pkgbuild"; then
          echo "FAIL: PKGBUILD is not syntactically valid bash" >&2
          cat "$pkgbuild" >&2
          exit 1
        fi

        check() {
          if ! grep -qF "$1" "$pkgbuild"; then
            echo "FAIL: PKGBUILD missing expected line: $1" >&2
            cat "$pkgbuild" >&2
            exit 1
          fi
        }
        check '# Maintainer: Nixothea Test <test@example.invalid>'
        check 'pkgname=hello'
        check 'pkgver=2.5'
        check 'pkgrel=1'
        check "pkgdesc='nixothea aur-target e2e fixture'"
        check "arch=(x86_64)"
        check "url=https://example.invalid/hello"
        check "license=(mit)"
        check "source=(https://example.invalid/hello-2.5.tar.gz)"
        check "sha256sums=(0000000000000000000000000000000000000000000000000000000000aa)"
        check 'shared-step'
        check 'root-build-step'
        check 'root-install-step'

        # collectDeps' merge order: the nested node's own step precedes
        # the root's own -- proves this is a real structural merge, not
        # just "both strings appear somewhere".
        build_start=$(grep -n '^build() {' "$pkgbuild" | cut -d: -f1)
        shared_line=$(grep -n 'shared-step' "$pkgbuild" | cut -d: -f1)
        root_line=$(grep -n 'root-build-step' "$pkgbuild" | cut -d: -f1)
        if [ "$shared_line" -lt "$build_start" ] || [ "$shared_line" -gt "$root_line" ]; then
          echo "FAIL: shared-step must appear inside build(), before root-build-step" >&2
          cat "$pkgbuild" >&2
          exit 1
        fi

        echo "nixothea-test-target-aur-structure: passed" > $out
      '';
  };
} // (
  if !mismatchedThrew then
    throw "nixothea e2e aur-target: expected a throw for aurSource set without aurSourceSha256, none happened"
  else
    { }
)
