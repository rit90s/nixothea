# A constructor: `nixothea.targets.docker { }` returns a target that
# produces a real, loadable layered OCI/Docker image tarball (via
# `pkgs.dockerTools.buildLayeredImage`) -- unlike aur/homebrew/flatpak,
# nixothea does the real compile itself here, the same as appimage.nix.
#
# Like appimage.nix, this target is fully self-contained: there's no host
# package manager to declare a runtime dependency to, so `resolve` always
# emits an empty section and `nativeDerivationFactory` is never called.
# Unlike appimage.nix, there's no manual closure-bundling to get right --
# `dockerTools.buildLayeredImage` already walks the full Nix runtime
# closure of whatever's listed in `contents` on its own
# (`includeStorePaths`, on by default), so listing every transitively-
# reachable node's own real build output is enough.
{ pkgs, mkTarget, collectDeps, targetImpl }:
let
  lib = pkgs.lib;
in
{
  # Image name/tag as `docker load`/`docker run` would reference them
  # (e.g. "myapp:1.2.3"). Default to the root package's own pname/version
  # when unset.
  imageName ? null,
  tag ? null,

  # Which binary under the root derivation's $out/bin/ becomes the image's
  # Entrypoint. Ignored (never even evaluated, since Nix is lazy) when
  # `entrypoint` is set explicitly. When both are unset, resolved from
  # $out/bin/: used directly if there's exactly one entry, otherwise the
  # build fails asking for one or the other to be set explicitly.
  mainProgram ? null,

  # Raw OCI Entrypoint override (e.g. [ "/bin/sh" "-c" "..." ]). When null,
  # defaults to [ "''${realDrv}/bin/''${mainProgram}" ].
  entrypoint ? null,

  # OCI Cmd -- default arguments appended after Entrypoint, overridable at
  # `docker run` time.
  cmd ? [ ],

  # OCI Env, as "KEY=VALUE" strings.
  env ? [ ],

  # OCI WorkingDir. Left at the image format's own default (usually "/")
  # when unset.
  workdir ? null,

  # OCI User (e.g. "1000:1000"). Left at the image format's own default
  # (root) when unset -- same reasoning as flatpak's `finishArgs`
  # defaulting to empty: a real security-relevant decision only the
  # caller can make correctly, deliberately not defaulted to anything.
  user ? null,

  # OCI ExposedPorts entries, e.g. [ "8080/tcp" ].
  exposedPorts ? [ ],

  # OCI Labels (arbitrary key/value metadata).
  labels ? { },

  # Extra store paths/derivations to bundle into the image alongside the
  # package's own closure -- e.g. `pkgs.cacert`, `pkgs.tzdata`, or a shell
  # for interactive debugging. None of these are inferred, same reasoning
  # as `user` above.
  extraContents ? [ ],

  # Passed straight through to `dockerTools.buildLayeredImage` -- caps how
  # many of the closure's store paths get their own image layer before
  # the rest are collapsed into one, trading image-layer cache reuse
  # (across multiple nixothea packages sharing dependencies) against
  # Docker's own hard 125-layer-per-image limit.
  maxLayers ? 100,

  # ISO-8601 image creation timestamp. Left at
  # `dockerTools.buildLayeredImage`'s own default
  # ("1970-01-01T00:00:01Z") when null, for reproducible builds -- set
  # explicitly (e.g. "now") for a real publish where a genuine build date
  # matters more than bit-for-bit reproducibility.
  created ? null,
}:
mkTarget {
  inherit pkgs lib;
  resolve = targetImpl.resolvers.empty "docker";
  inherit (import ./builder.nix {
    inherit lib collectDeps imageName tag mainProgram entrypoint cmd env workdir exposedPorts labels user extraContents maxLayers created targetImpl;
  }) nativeDerivationFactory mkDerivation;
}
