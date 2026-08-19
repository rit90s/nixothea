# End-to-end test of utils/debug/mk-dev-shells.nix against the real `nix`
# target: the resolved dependency really reaches `definition`'s
# `buildInputs` argument (asserted directly, by overriding `definition` to
# expose the raw list -- exactly the customization the function documents
# as supported), and the default `definition` (a real `pkgs.mkShell` call)
# constructs without error.
#
# The default-definition check is deliberately structural
# (`defaultShells.nix ? drvPath`), not a real `nix build` of it: a real
# `pkgs.mkShell` pulls in a full compiler toolchain as `nativeBuildInputs`
# (genuinely correct/expected -- that's what makes it a usable dev shell),
# and forcing that shell's `.drvPath` as a build input of this check (as
# an earlier version of this test did) turned out to force realizing that
# *entire* closure -- hundreds of MB on a cold cache -- which buys little
# over the structural check for what this test is actually verifying.
{ pkgs, nixTarget }:
let
  lib = pkgs.lib;
  mkDevShells = import ../../utils/debug/mk-dev-shells.nix;

  myTargets = { nix = nixTarget; };
  lockFile = builtins.toFile "dev-shells-lock.json" (builtins.toJSON {
    targets.nix = { compression = { name = "zlib"; }; };
  });

  namedShells = mkDevShells {
    targets = myTargets;
    inherit lockFile;
    definition = { pkgs, buildInputs }: buildInputs;
  };
  names = map (d: d.pname or d.name or "?") namedShells.nix;

  defaultShells = mkDevShells { targets = myTargets; inherit lockFile; };
  defaultConstructsOk = defaultShells.nix ? drvPath;
in
pkgs.runCommand "nixothea-test-e2e-dev-shells" { }
  (
    if names != [ "zlib" ] then
      throw "nixothea e2e dev-shells: expected buildInputs [ \"zlib\" ], got ${builtins.toJSON names}"
    else if !defaultConstructsOk then
      throw "nixothea e2e dev-shells: the default (pkgs.mkShell-based) definition didn't produce a derivation-shaped value"
    else
      ''echo "nixothea-test-e2e-dev-shells: passed" > $out''
  )
