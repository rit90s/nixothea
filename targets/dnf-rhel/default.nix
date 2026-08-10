# A constructor: `nixothea.targets.dnfRhel { repos = [...]; releasever = "10-stream"; }`
# returns a target that builds a real .rpm against the RHEL family, using
# CentOS Stream as the concrete distro (freely accessible without a
# subscription, unlike RHEL itself; Rocky/Alma would need their own pinned
# keyring, since they don't share CentOS Stream's signing key). Same idea
# as dnf-fedora -- see that target's comments for the parts that are
# identical (whatprovides-based Requires resolution, Provides:-based
# library classification, AutoReqProv: no, etc.) -- only the differences
# specific to CentOS Stream are called out here.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;
in
{
  # Where to resolve/fetch packages from -- mandatory, no default, same
  # reasoning as deb's `repos` and dnf-fedora's `repos`. Each entry becomes
  # one dnf repo stanza, e.g. { id = "baseos"; baseurl =
  # "https://mirror.stream.centos.org/$releasever/BaseOS/$basearch/os/"; }
  # -- CentOS Stream splits runtime packages into BaseOS and most -devel
  # packages into AppStream, so most callers will want both.
  repos,

  # Also mandatory, same reasoning as dnf-fedora's `releasever`. Note this
  # is CentOS Stream's own directory-name convention, e.g. "10-stream" or
  # "9-stream" -- not a bare number like Fedora's "44".
  releasever,

  architecture ? "x86_64",

  vendor ? null,
  license ? "unspecified",
  group ? "Unspecified",
}:
let
  keyring = import ./keyring.pkg.nix { inherit pkgs; };

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
