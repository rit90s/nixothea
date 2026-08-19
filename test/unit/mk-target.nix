# Unit tests for lib/mk-target.nix -- purely a validating constructor, so
# every case here is either "does it pass the given shape through
# unchanged" or "does it throw for this specific malformed field".
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  mkTarget = import ../../lib/mk-target.nix;

  # Functions aren't comparable with `==` in Nix, so "passed through
  # unchanged" is asserted by calling each one back and checking for a
  # distinctive marker, not by identity comparison.
  validArgs = {
    inherit lib pkgs;
    resolve = { pkgs, deps }: "resolve-marker";
    nativeDerivationFactory = { pkgs, name, entry }: "native-marker";
    mkDerivation = { pkgs, role, name, realDrv, nodeDeps, dependencyDeps, args }: "mkderivation-marker";
  };
in
[
  {
    name = "valid target: returns pkgs/resolve/nativeDerivationFactory/mkDerivation unchanged";
    expr =
      let t = mkTarget validArgs;
      in
      # Not `t.pkgs == pkgs`: `==` on two large real nixpkgs attrsets
      # forces a deep, key-by-key comparison rather than short-circuiting
      # on identity, and real nixpkgs has attributes that throw just from
      # being accessed (e.g. removed packages) -- `t.pkgs ? stdenv` is
      # enough to confirm it's a real pkgs, not a copy or a stub.
      [
        (t.pkgs ? stdenv)
        (t.resolve { pkgs = null; deps = null; } == "resolve-marker")
        (t.nativeDerivationFactory { pkgs = null; name = null; entry = null; } == "native-marker")
        (t.mkDerivation { pkgs = null; role = null; name = null; realDrv = null; nodeDeps = null; dependencyDeps = null; args = null; } == "mkderivation-marker")
      ];
    expected = [ true true true true ];
  }
  {
    name = "valid target: lintRules defaults to {}";
    expr = (mkTarget validArgs).lintRules;
    expected = { };
  }
  {
    name = "valid target: explicit lintRules passed through unchanged";
    expr =
      let
        rules = { someRule = { pkgs, lockSection, tree, options }: null; };
        t = mkTarget (validArgs // { lintRules = rules; });
      in
      builtins.attrNames t.lintRules;
    expected = [ "someRule" ];
  }
  {
    name = "throws when pkgs is null";
    expr = mkTarget (validArgs // { pkgs = null; });
    throws = true;
  }
  {
    name = "throws when resolve is not a function";
    expr = mkTarget (validArgs // { resolve = "not a function"; });
    throws = true;
  }
  {
    name = "throws when nativeDerivationFactory is not a function";
    expr = mkTarget (validArgs // { nativeDerivationFactory = { }; });
    throws = true;
  }
  {
    name = "throws when mkDerivation is not a function";
    expr = mkTarget (validArgs // { mkDerivation = 42; });
    throws = true;
  }
  {
    name = "throws when a lintRules entry is not a function";
    expr = mkTarget (validArgs // { lintRules = { bad = "not a function"; }; });
    throws = true;
  }
]
