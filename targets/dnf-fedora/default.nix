# A constructor: `nixothea.targets.dnfFedora { repos = [...]; releasever = "44"; }`
# returns a target that builds a real .rpm, with runtime dependencies
# fetched as real .rpm files and extracted during the build -- same idea as
# deb, adapted to dnf5/rpm. Specific to Fedora: the GPG keyring
# (keyring.pkg.nix) is pinned from Fedora's own fedora-gpg-keys package,
# so this target can't just be re-instantiated under a different name to
# target a different RPM distro (see dnf-rhel/ and dnf-opensuse/ for
# those -- each needs its own keyring).
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;
in
{
  # Where to resolve/fetch packages from -- mandatory, no default, for the
  # same reason as deb's `repos`: silently defaulting to some particular
  # Fedora mirror is an implicit choice a caller should have to make
  # explicitly. Each entry becomes one dnf repo stanza, e.g.
  # { id = "fedora"; baseurl = "https://dl.fedoraproject.org/pub/fedora/linux/releases/$releasever/Everything/$basearch/os/"; }.
  repos,

  # Also mandatory, for the same reason: which Fedora release's package set
  # to resolve against is exactly the kind of implicit choice that
  # shouldn't have a silent default.
  releasever,

  architecture ? "x86_64",

  vendor ? null,
  license ? "unspecified",
  group ? "Unspecified",
}:
let
  keyring = import ./keyring.pkg.nix { inherit pkgs releasever; };

  reposFile = pkgs.writeText "nixothea.repo" (lib.concatMapStringsSep "\n\n"
    (repo: ''
      [${repo.id}]
      name=${repo.id}
      baseurl=${repo.baseurl}
      enabled=1
      gpgcheck=1
      repo_gpgcheck=0
      gpgkey=file://${keyring}
    '')
    repos);
in
mkTarget {
  inherit lib;
  resolve = import ./resolver.nix { inherit lib releasever architecture reposFile keyring; };
  inherit (import ./builder.nix { inherit lib collectDeps architecture vendor license group; })
    nativeDerivationFactory mkDerivation;
}
