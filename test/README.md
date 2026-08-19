# Tests

Tests for the core (`lib/` -- `mkTarget`/`mkResolver`/`buildTarget`/
`collectDeps`, plus the shared node semantics in
`lib/wrap-mk-derivation.nix` -- and `utils/`, see
[`doc/utils/`](../doc/utils/README.md)), plus a growing per-target e2e
suite (`test/e2e/targets/`) that actually runs each pre-implemented
target's real output, not just builds it.

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
- **`e2e/targets/`** -- one module per pre-implemented target
  (`test/e2e/targets/<name>.nix`), each returning
  `{ checks = { ... }; apps = { ... } ? {}; }`, covering all 15
  pre-implemented targets. `checks` entries are real, sandboxed builds --
  for formats directly runnable on Linux with no extra host tooling
  (`nix`, `appimage` via `--appimage-extract-and-run`, `tarball`), the
  produced artifact is actually extracted/executed inside the check
  itself and its real output checked, not just its existence; for
  recipe-only targets that never compile real software themselves (`aur`,
  `homebrew`, `flatpak`'s structural check), the generated recipe is
  parsed for real by the real tool that would eventually consume it
  (`bash -n`, `ruby -c`, `jq`) and its content verified field by field.
  `apps` entries exist where the sandbox genuinely can't do the real
  thing (real rootless `podman` was confirmed, while designing these, to
  work fine as an ordinary host process but to fail nested inside Nix's
  own build sandbox -- missing `/etc/subuid` and other privilege-adjacent
  setup a sandboxed build doesn't have) -- those are `nix run`-able
  instead, real host processes: real container engine (`docker`, `snap`,
  `deb`, `apk`, `dnfFedora`, `dnfRhel`, `dnfOpensuse`), real
  `flatpak-builder` against a real installed runtime+SDK (`flatpak`), or
  real Wine (`windowsExe`, `windowsMsi`). `aur`/`homebrew` have no `apps`
  entry at all -- real execution would need `pacman`/`brew` themselves,
  and unlike every other target, this target's whole design point is
  that nixothea never compiles real software for it in the first place
  (see aur.nix/homebrew.nix's own header comments).

## Running

```console
$ nix flake check
```

Builds every check in `checks.${system}` -- `unit-*` (fast, pure eval),
`e2e-*` (real builds, e.g. a genuine tarball closure), and `target-*-*`
(real per-target builds, some directly executed) alike.

For faster local iteration:

```console
$ nix run .#test-unit                     # prints every unit module's results, doesn't stop at the first failure
$ nix run .#test-e2e                      # nix build's every core e2e check with streamed logs
$ nix run .#test-target-docker-run        # real podman load+run of the docker target's real image
$ nix run .#test-target-snap-run          # real podman + a real ubuntu:noble container running the snap target's real payload
$ nix run .#test-target-deb-run           # real podman + a real debian:bookworm container, real apt install
$ nix run .#test-target-apk-run           # real podman + a real alpine:3.20 container, real apk install
$ nix run .#test-target-dnfFedora-run     # real podman + a real fedora:44 container, real dnf install
$ nix run .#test-target-dnfRhel-run       # real podman + a real centos:stream10 container, real dnf install
$ nix run .#test-target-dnfOpensuse-run   # real podman + a real opensuse/leap:15.6 container, real zypper install
$ nix run .#test-target-flatpak-run       # real flatpak-builder against a real installed runtime+SDK
$ nix run .#test-target-windowsExe-run    # real Wine, real NSIS installer silent-installed and run
$ nix run .#test-target-windowsMsi-run    # real Wine, real MSI installed via msiexec and run
```

Or build/inspect one check directly, same as any other flake output:

```console
$ nix build .#checks.x86_64-linux.e2e-pipeline -L
$ nix build .#checks.x86_64-linux.target-appimage-run -L
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
- Every real package-manager-based target's (`snap`, `deb`, `apk`,
  `dnfFedora`, `dnfRhel`, `dnfOpensuse`) dependency lock entry is
  hand-crafted with a real, currently-valid url/sha256 obtained by hand
  while writing each test (same reasoning as `test/e2e/pipeline.nix`'s
  own lock file -- `resolve` itself needs a live network round-trip
  against a real registry, which can't run inside a sandboxed check). If
  the upstream archive ever removes that exact package version, the
  affected check starts failing on the `fetchurl` step until the hash is
  refreshed -- not a design flaw, just a maintenance fact of pinning
  against a real, mutable upstream. `dnfOpensuse`'s own archive turned
  out to be unusually volatile even by that standard: openSUSE's official
  container image ships Update-repo packages baked in even for a
  nominally frozen "distribution" release (confirmed by hand -- the
  installed `libz1` had already moved past what the `oss` tree itself
  still serves), so its `apps.run` needs `zypper --force-resolution` to
  downgrade to the pinned version rather than relying on version drift
  never happening.
- `aur`/`homebrew`'s per-target coverage is structural only (real
  `bash -n`/`ruby -c` parses of the generated recipe, not a real
  `makepkg`/`brew install`) -- by design, not an environment limitation:
  see `test/e2e/targets/aur.nix`/`homebrew.nix`'s own header comments for
  why real execution is out of scope for these two specifically.
- `flatpak`'s `apps.run` needs a real ~1-2GiB runtime+SDK download from
  Flathub the first time it runs (cached under the invoking user's own
  `--user` Flatpak installation afterward, the same way the container-
  based apps above reuse the host's real podman storage) and
  `--disable-rofiles-fuse` (a real FUSE mount that fails in this
  environment even though `/dev/fuse` itself is present).
- `windowsExe`/`windowsMsi`'s `apps.run` need `pkgs.wineWow64Packages`
  specifically, not the older `wineWowPackages` alias for the same
  underlying package -- confirmed by hand that the deprecated alias
  resolves to a differently-derived build Hydra hasn't cached under this
  flake's pinned nixpkgs revision, forcing an hours-long from-source Wine
  compile; the non-deprecated name is cached.

[Back to the main README](../README.md)
