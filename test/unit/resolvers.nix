# Unit tests for utils/targetImpl/resolvers.nix -- construction-level
# checks only (both bodies build a real writeShellApplication derivation,
# so eval-time forcing already exercises shellcheck's own build -- that
# crosses into e2e; see test/e2e/pipeline.nix, which runs a target built
# with `resolvers.passthrough` for real end to end).
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  resolvers = import ../../utils/targetImpl/resolvers.nix;
in
[
  {
    name = "empty: names the generated derivation resolve-<targetName>";
    expr = (resolvers.empty "mytarget" { inherit pkgs; deps = { }; }).name;
    expected = "resolve-mytarget";
  }
  {
    name = "empty: ignores deps entirely -- still constructs regardless of what's passed";
    expr = builtins.seq (resolvers.empty "mytarget" { inherit pkgs; deps = { zlib = { name = "z"; }; }; }).drvPath true;
    expected = true;
  }
  {
    name = "passthrough: names the generated derivation resolve-<targetName>";
    expr = (resolvers.passthrough "mytarget" { inherit pkgs; deps = { }; }).name;
    expected = "resolve-mytarget";
  }
]
