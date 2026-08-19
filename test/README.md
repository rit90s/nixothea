# Tests

Tests for the core: `lib/` (`mkTarget`/`mkResolver`/`buildTarget`/
`collectDeps`, plus the shared node semantics in
`lib/wrap-mk-derivation.nix`) and `utils/` (`sameEntry`/`targetImpl`/
`debug`, see [`doc/utils/`](../doc/utils/README.md)). Not the fifteen
pre-implemented `targets/` themselves -- those are documented and verified
individually in [`doc/targets/`](../doc/targets/README.md).

- **`unit/`** -- pure Nix-language evaluation against a fake, minimal
  target (`test/fixtures.nix`), never a real one. Exercises the generic
  framework machinery in isolation: node semantics, dependency
  slicing/deduplication, asserts, throws. No sandboxed build step is
  required for a case to fail -- see `test/lib.nix`'s header comment for
  how a "must throw" case is expressed (and its one real limitation: Nix
  has no way to inspect a thrown message from pure code, only whether one
  happened).
- **`e2e/`** -- real builds and real script executions against real,
  pre-implemented targets (`nix`, `aur`, `tarball` -- chosen because all
  three are network-free, so these run safely inside the Nix build
  sandbox). Each check's own build script performs its assertions for
  real and fails the build on mismatch.

## Running

```console
$ nix flake check
```

Builds every check in `checks.${system}` -- `unit-*` (fast, pure eval)
and `e2e-*` (real builds, e.g. a genuine tarball closure) alike.

For faster local iteration:

```console
$ nix run .#test-unit    # prints every unit module's results, doesn't stop at the first failure
$ nix run .#test-e2e     # nix build's every e2e check with streamed logs
```

Or build/inspect one check directly, same as any other flake output:

```console
$ nix build .#checks.x86_64-linux.e2e-pipeline -L
```

## Known gaps

- `mkResolver`'s `isReliablyNative`/`resolvePkgs` selection logic (picking
  a safe, reliably-native pkgs among mixed targets -- see the comment in
  `lib/resolver.nix`) isn't covered: exercising it meaningfully needs
  multiple real pkgs variants (a genuine cross pkgs, a musl pkgs, ...)
  instantiated side by side, which is expensive for what it'd add over
  the existing code comments/manual verification.
- `autoDetectMainProgram`'s "expect a throw" path is checked directly
  (`test/e2e/main-program.nix`), but only via the function itself against
  real fixture derivations -- not by provoking a real `nix build` failure
  through an actual pre-implemented target end to end, which would need
  invoking the `nix` CLI as a subprocess (fine for an app, not for a
  sandboxed check).
- Targets other than `nix`/`aur`/`tarball` (anything needing network
  access to resolve against a live registry -- `deb`, `apk`, `dnf*`, ...)
  aren't exercised here at all; they're covered individually in
  [`doc/targets/`](../doc/targets/README.md) instead.

[Back to the main README](../README.md)
