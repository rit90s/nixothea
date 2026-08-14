# A target implements the phases nixothea drives. A target has no name of
# its own -- the caller assigns it one by the attrset key it's placed
# under when building the `targets` attrset passed to `mkResolver`/
# `buildTarget`, so the same target implementation can be instantiated
# multiple times under different names (e.g. a `deb` target configured once
# as `debian` and once as `ubuntu`, each with its own repos).
#
# `pkgs` is the pkgs *this target itself* builds against -- fixed once,
# here, at construction time, rather than supplied later by whoever calls
# `mkResolver`/`buildTarget`. This is what lets one `buildTarget`/
# `mkResolver` call freely mix targets that fundamentally need different
# pkgs -- e.g. a Linux-native `deb` target alongside `windowsExe` (which
# needs a real Windows cross pkgs like `pkgsCross.mingwW64`) or `apk`
# (which needs a musl pkgs) -- without the caller having to run separate
# calls per platform, or risk a target silently building against the
# wrong pkgs. A target that needs something other than the plain pkgs
# it's handed derives that itself from it (see
# targets/windows-exe/default.nix, targets/apk/default.nix) rather than
# expecting the caller to know to supply it.
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
#     version. `pkgs` here is *not* necessarily this target's own `pkgs`
#     above -- mkResolver always builds `resolve` with safe, reliably-
#     native build-machine tooling regardless (see lib/resolver.nix),
#     since resolving is a network/CLI-tool operation, never something
#     that needs to be built *for* whatever platform the target itself
#     targets.
#
#   nativeDerivationFactory : { pkgs, name, entry }: <value>
#     Called once per dependency found in this target's lock-file section
#     (`name` = the logical dependency name, `entry` = whatever `resolve`
#     put in the lock file for it). Turns one resolved dependency into
#     whatever this target considers its "native" representation of it --
#     the value exposed as `pkgs.<name>` to package definitions built
#     against this target. What that actually is is entirely target
#     -specific: a real derivation if the target fetches/builds the
#     dependency for real, purely descriptive metadata if it doesn't (e.g.
#     an AUR target, where dependencies are just names for a PKGBUILD's
#     depends= array, resolved externally by pacman later). Must return an
#     attrset (the framework tags it before exposing it).
#
#   mkDerivation : { pkgs, role, name, realDrv, nodeDeps, dependencyDeps, args }: <result>
#     The target-specific half of `pkgs.mkDerivation` -- the framework
#     handles the mechanical part (validating buildInputs, building the
#     real derivation, deduplicating nested nodes; see
#     wrap-mk-derivation.nix) and calls this with the result. `role` is
#     "root" (this is the final thing definition returned) or "dependency"
#     (this was reached via another node's buildInputs/
#     propagatedBuildInputs, with `name` set to its own pname). `realDrv`
#     is the real derivation Nix constructed from `args` -- cheap to read
#     metadata off (`.pname`, `.version`, ...) regardless of whether
#     anything ever forces it to actually build, which some targets (e.g.
#     AUR, where there's no real Nix build to speak of) never do.
#     `nodeDeps`/`dependencyDeps` are this node's own direct nested
#     nixothea nodes/dependencies (already deduplicated), for the target's
#     merge logic to fold in; `args` is the raw attrset passed to
#     pkgs.mkDerivation, for targets that need more than realDrv's
#     metadata (e.g. the literal buildPhase/installPhase text). Every node
#     also exposes its own `.nodeDeps`/`.dependencyDeps`/`.args` directly
#     (single-level only, same as here) -- so a nested node's own nested
#     deps can be inspected structurally, without having to call it with
#     `role = "dependency"` first. For the *whole* transitively-reachable
#     tree (every dependency nested at any depth, deduplicated), see
#     `collectDeps` in collect-deps.nix.
{ lib, pkgs, resolve, nativeDerivationFactory, mkDerivation }:
assert lib.assertMsg (pkgs != null)
  "nixothea: target.pkgs must be set -- the pkgs this target itself builds against";
assert lib.assertMsg (builtins.isFunction resolve)
  "nixothea: target.resolve must be a function of { pkgs, deps }";
assert lib.assertMsg (builtins.isFunction nativeDerivationFactory)
  "nixothea: target.nativeDerivationFactory must be a function of { pkgs, name, entry }";
assert lib.assertMsg (builtins.isFunction mkDerivation)
  "nixothea: target.mkDerivation must be a function of { pkgs, role, name, realDrv, nodeDeps, dependencyDeps, args }";
{ inherit pkgs resolve nativeDerivationFactory mkDerivation; }
