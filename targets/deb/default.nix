# A constructor: `nixothea.targets.deb { repos = [...]; }` returns a
# target that builds a real .deb, with runtime dependencies fetched as real
# .deb files and extracted during the build -- unlike aur, where a
# dependency is just metadata, here it has to be a real, linkable
# derivation, since the whole point is that the real Nix build (buildPhase
# etc) can actually compile/link against it, the way a real Debian build
# would. The same target implementation can be instantiated more than once
# under different names (e.g. `debian`/`ubuntu`, each with their own repos).
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;
in
{
  # Where to resolve/fetch packages from -- mandatory, no default, since
  # silently defaulting to some particular Debian mirror/suite is exactly
  # the kind of implicit choice a caller should have to make explicitly.
  # Each entry becomes one `deb <url> <suite> <components...>` sources.list
  # line, e.g. { url = "https://deb.debian.org/debian"; suite = "bookworm"; components = [ "main" ]; }.
  repos,

  architecture ? "amd64",

  maintainer ? null,
  section ? "misc",
  priority ? "optional",
}:
let
  keyring = import ./keyring.pkg.nix { inherit pkgs; };

  sourcesList = pkgs.writeText "sources.list" (lib.concatMapStringsSep "\n"
    (repo: "deb ${repo.url} ${repo.suite} ${lib.concatStringsSep " " repo.components}")
    repos);
in
mkTarget {
  inherit pkgs lib;
  resolve = import ./resolver.nix { inherit lib architecture sourcesList keyring; };
  inherit (import ./builder.nix { inherit lib collectDeps architecture maintainer section priority; })
    nativeDerivationFactory mkDerivation;
}
