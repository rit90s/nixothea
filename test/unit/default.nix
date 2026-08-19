# Aggregates the unit suite: pure Nix-language evaluation (plus cheap,
# unrealized derivation construction) against a fake target
# (test/fixtures.nix), never a real one -- see test/e2e/ for that.
{ pkgs }:
let
  lib = pkgs.lib;
  fixtures = import ../fixtures.nix { inherit pkgs; };
  harness = import ../lib.nix { inherit lib; };

  modules = {
    mk-target = import ./mk-target.nix { inherit pkgs fixtures; };
    wrap-mk-derivation = import ./wrap-mk-derivation.nix { inherit pkgs fixtures; };
    collect-deps = import ./collect-deps.nix { inherit pkgs fixtures; };
    build = import ./build.nix { inherit pkgs fixtures; };
    resolver = import ./resolver.nix { inherit pkgs fixtures; };
    same-entry = import ./same-entry.nix { inherit pkgs fixtures; };
    license-names = import ./license-names.nix { inherit pkgs fixtures; };
    resolvers = import ./resolvers.nix { inherit pkgs fixtures; };
    referenced-dependency-names = import ./referenced-dependency-names.nix { inherit pkgs fixtures; };
  };

  checks = builtins.mapAttrs (name: cases: harness.mkCheck { inherit pkgs name cases; }) modules;

  report = pkgs.writeShellApplication {
    name = "nixothea-test-unit";
    text = ''
      failed=0
      ${lib.concatMapStringsSep "\n" (name: ''
        echo "--- unit: ${name} ---"
        if ! ${lib.getExe (harness.mkReport { inherit pkgs name; cases = modules.${name}; })}; then
          failed=1
        fi
      '') (builtins.attrNames modules)}
      if [ "$failed" -eq 1 ]; then
        echo "nixothea-test-unit: failures found (see above)" >&2
        exit 1
      fi
      echo "nixothea-test-unit: all unit tests passed"
    '';
  };
in
{ inherit checks report; }
