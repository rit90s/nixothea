# End-to-end test of utils/debug/lint-dependencies.nix: real build, real
# execution of the generated `nixothea-lint` script, against a fixture
# with a genuinely unused dependency (expect a nonzero exit mentioning it)
# and a clean fixture (expect exit 0) -- both against the real `nix`
# target.
{ pkgs, nixTarget }:
let
  lib = pkgs.lib;
  lintDependencies = import ../../utils/debug/lint-dependencies.nix;

  myTargets = { nix = nixTarget; };

  lockUnused = builtins.toFile "lint-lock-unused.json" (builtins.toJSON {
    targets.nix = { zlib = { name = "zlib"; }; curl = { name = "curl"; }; };
  });
  lockClean = builtins.toFile "lint-lock-clean.json" (builtins.toJSON {
    targets.nix = { zlib = { name = "zlib"; }; };
  });

  # `curl` is declared but never referenced -- the fixture the "unused"
  # lock file above is paired with.
  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "p"; version = "1";
      dontUnpack = true;
      buildInputs = [ pkgs.zlib ];
      buildPhase = "true";
      installPhase = "mkdir -p $out";
    };

  lintUnused = lintDependencies { targets = myTargets; lockFile = lockUnused; inherit definition; };
  lintClean = lintDependencies { targets = myTargets; lockFile = lockClean; inherit definition; };
in
pkgs.runCommand "nixothea-test-e2e-lint"
  {
    unusedExe = lib.getExe lintUnused;
    cleanExe = lib.getExe lintClean;
  }
  ''
    if "$unusedExe" 2> unused.err; then
      echo "FAIL: lint on the fixture with an unused dependency should have exited nonzero" >&2
      cat unused.err >&2
      exit 1
    fi
    if ! grep -q 'builtin.unused' unused.err; then
      echo "FAIL: lint output didn't mention builtin.unused" >&2
      cat unused.err >&2
      exit 1
    fi
    if ! grep -q '"curl"' unused.err; then
      echo "FAIL: lint output didn't name the unused dependency (curl)" >&2
      cat unused.err >&2
      exit 1
    fi

    if ! "$cleanExe" > clean.out 2>&1; then
      echo "FAIL: lint on the clean fixture should have exited 0" >&2
      cat clean.out >&2
      exit 1
    fi

    echo "nixothea-test-e2e-lint: passed" > $out
  ''
