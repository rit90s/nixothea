# Unit tests for lib/resolver.nix (mkResolver) -- specifically the
# per-target dependency slicing (`sliceFor`), which is otherwise only
# observable by actually running the generated script (an e2e concern,
# see test/e2e/pipeline.nix). Exploited here instead: `dispatch` (used to
# build the wrapper script's *text*) forces every target's `resolve` the
# moment mkResolver's returned derivation's `.drvPath` is accessed -- which
# forces the whole attrset to be evaluated into concrete strings, but
# still never runs or builds anything -- so a fake `resolve` that asserts
# on the `deps` slice it was called with turns "was slicing correct" into
# a plain throw/no-throw check.
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  mkResolver = import ../../lib/resolver.nix;

  assertingResolve = expectedDeps: { pkgs, deps }:
    if deps == expectedDeps
    then pkgs.writeShellApplication { name = "fake-resolve"; text = "echo '{}'"; }
    else throw "sliceFor produced ${builtins.toJSON deps}, expected ${builtins.toJSON expectedDeps}";

  mkTargetWith = expectedDeps: fixtures.mkFakeTarget { resolve = assertingResolve expectedDeps; };

  # Forces full construction of mkResolver's returned derivation (which in
  # turn forces every target's `resolve` call, see header) without ever
  # building or running it.
  force = args: builtins.seq (mkResolver args).drvPath true;
in
[
  {
    name = "each target's resolve only sees the entries that declared something under its own name";
    expr = force {
      dependencies = {
        zlib = { a = { name = "zlib-a"; }; b = { name = "zlib-b"; }; };
        curl = { a = { name = "curl-a"; }; };
      };
      targets = {
        a = mkTargetWith { zlib = { name = "zlib-a"; }; curl = { name = "curl-a"; }; };
        b = mkTargetWith { zlib = { name = "zlib-b"; }; };
      };
    };
    expected = true;
  }
  {
    name = "a target with no matching entries anywhere gets an empty slice, not a missing attribute";
    expr = force {
      dependencies = { zlib = { a = { name = "zlib-a"; }; }; };
      targets = { a = mkTargetWith { zlib = { name = "zlib-a"; }; }; c = mkTargetWith { }; };
    };
    expected = true;
  }
  {
    name = "a logical dependency with an explicit null entry for a target is excluded from that target's slice, same as not declaring it at all";
    expr = force {
      dependencies = { zlib = { a = null; }; };
      targets = { a = mkTargetWith { }; };
    };
    expected = true;
  }
  {
    name = "a wrong expected slice (sanity check on the harness itself) does throw";
    expr = force {
      dependencies = { zlib = { a = { name = "zlib-a"; }; }; };
      targets = { a = mkTargetWith { zlib = { name = "wrong-name"; }; }; };
    };
    throws = true;
  }
]
