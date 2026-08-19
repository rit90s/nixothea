# Shared fixtures for unit/ -- a fake, minimal target whose `mkDerivation`
# surfaces exactly the fields a test needs to assert on (role, which
# nested nodes/dependencies got merged) instead of implementing any real
# packaging policy the way an actual target does. Lets unit tests exercise
# the framework's own generic machinery (wrap-mk-derivation.nix's node
# semantics, collectDeps, buildTarget's dispatch) without depending on any
# one real target's behavior.
{ pkgs }:
let
  lib = pkgs.lib;
  wrapMkDerivation = import ../lib/wrap-mk-derivation.nix;
in
rec {
  inherit pkgs lib;

  # { resolve ? ...; nativeDerivationFactory ? ...; lintRules ? {}; }: <target>
  # Every field has a workable default; override just what a given test
  # cares about. The default `nativeDerivationFactory` returns `entry`
  # itself unchanged, tagged by the caller (mirroring what build.nix's own
  # `customDeps` does) -- so a lock entry `{ name = "x"; outPath = ...; }`
  # flows straight through as that dependency's `pkgs.<name>` value.
  mkFakeTarget =
    { resolve ? (_: throw "fake target: resolve not configured")
    , nativeDerivationFactory ? ({ pkgs, name, entry }: entry)
    , lintRules ? { }
    }:
    {
      inherit pkgs resolve nativeDerivationFactory lintRules;
      mkDerivation = { pkgs, role, name, realDrv, nodeDeps, dependencyDeps, args }:
        realDrv // {
          fakeRole = role;
          fakeName = name;
          fakeNodeNames = map (n: n.realDrv.pname) nodeDeps;
          fakeDependencyNames = map (d: d._nixotheaDependencyName) dependencyDeps;
        };
    };

  # The `pkgs.mkDerivation` a `definition` sees when built against one
  # fake target -- just the wrapper itself, no resolved dependencies
  # merged in (unit tests that need a resolved dependency build one by
  # hand instead, tagged the same way build.nix's `customDeps` tags one:
  # see `mkFakeDependency` below).
  mkTargetPkgs = target: {
    mkDerivation = wrapMkDerivation { inherit pkgs target; };
  };

  # A resolved dependency value, tagged exactly the way build.nix tags
  # whatever `nativeDerivationFactory` returns -- for placing directly in
  # a fake node's `buildInputs` without going through a real lock file.
  # `hasRealDrv = true` reuses a genuine, cheap nixpkgs derivation
  # (`pkgs.hello`) rather than a hand-rolled fake attrset -- real code
  # (wrap-mk-derivation.nix's `unwrap`) hands this straight to
  # `stdenv.mkDerivation`'s own `buildInputs`, which expects a real
  # derivation's shape, not just something with an `outPath`-shaped
  # attribute. `hasRealDrv = false` mirrors a metadata-only dependency
  # (e.g. an AUR target's), which never has a real derivation to begin
  # with.
  mkFakeDependency = { name, hasRealDrv ? true }:
    (if hasRealDrv then pkgs.hello else { })
    // { _nixotheaDependency = true; _nixotheaDependencyName = name; };
}
