# Wires test/unit/ and test/e2e/ into `checks.${system}`/`apps.${system}`
# (see flake.nix). `nixothea = self`, so the test suite exercises the
# flake's own real `lib`/`targets` outputs, the same way any consumer
# would -- see test/README.md for how to run these.
{ pkgs, nixothea, system }:
let
  lib = pkgs.lib;
  unit = import ./unit { inherit pkgs; };
  e2e = import ./e2e { inherit pkgs nixothea system; };
in
{
  checks =
    (lib.mapAttrs' (name: drv: lib.nameValuePair "unit-${name}" drv) unit.checks)
    // (lib.mapAttrs' (name: drv: lib.nameValuePair "e2e-${name}" drv) e2e.checks);

  apps = {
    test-unit = { type = "app"; program = "${unit.report}/bin/nixothea-test-unit"; };
    test-e2e = { type = "app"; program = "${e2e.report}/bin/nixothea-test-e2e"; };
  };
}
