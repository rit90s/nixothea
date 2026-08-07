# A target implements the two phases nixothea drives. A target has no name
# of its own -- the caller assigns it one by the attrset key it's placed
# under when building the `targets` attrset passed to `mkResolver`/
# `buildTarget`, so the same target implementation can be instantiated
# multiple times under different names (e.g. a `deb` target configured once
# as `debian` and once as `ubuntu`, each with its own repos).
#
#   resolve : { pkgs, deps }: <derivation>
#     `deps` is this target's slice of the dependency spec: an attrset
#     { <logicalName> = <this target's entry for it>; } containing only the
#     logical dependencies that declared an entry for this target's name.
#     Must return a derivation with `meta.mainProgram` set, runnable via
#     `nix run` -- resolution is inherently impure (it may hit the network
#     to turn a version range into a concrete version/url/hash), so it runs
#     outside the Nix sandbox rather than as a normal build. Running it must
#     print this target's lock-file section as JSON to stdout. The
#     section's schema is entirely up to the target, as long as every entry
#     carries at least the logical name, real name, and concrete resolved
#     version.
#
#   mkDerivation : { pkgs, lockSection }: (attrs -> derivation)
#     `lockSection` is this target's already-resolved section of the lock
#     file (whatever `resolve` printed for it). Returns a drop-in
#     replacement for `pkgs.mkDerivation`: calling it from inside a package
#     definition, evaluated against this target, is what produces the final
#     packaged derivation (e.g. the .deb-building derivation).
{ lib, resolve, mkDerivation }:
assert lib.assertMsg (builtins.isFunction resolve)
  "nixothea: target.resolve must be a function of { pkgs, deps }";
assert lib.assertMsg (builtins.isFunction mkDerivation)
  "nixothea: target.mkDerivation must be a function of { pkgs, lockSection }";
{ inherit resolve mkDerivation; }
