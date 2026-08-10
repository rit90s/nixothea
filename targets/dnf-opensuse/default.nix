# A constructor: `nixothea.targets.dnfOpensuse { repos = [...]; releasever = "15.6"; }`
# returns a target that builds a real .rpm against openSUSE Leap. Named
# "dnf" rather than "zypper" for an honest reason: neither zypper nor
# libzypp are packaged in nixpkgs, so there's no zypper binary to reuse.
# openSUSE's repos publish standard createrepo-format repodata though
# (repomd.xml/primary.xml.gz -- the same schema dnf/libsolv already read),
# so dnf5 can query and download from them directly, verified empirically
# against a real Leap 15.6 repo. Same idea as dnf-fedora/dnf-rhel
# otherwise -- see dnf-fedora's comments for the parts that are identical
# (whatprovides-based Requires resolution, Provides:-based library
# classification, AutoReqProv: no, etc.).
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;
in
{
  # Where to resolve/fetch packages from -- mandatory, no default, same
  # reasoning as the other targets' `repos`. Each entry becomes one dnf
  # repo stanza, e.g. { id = "oss"; baseurl =
  # "https://download.opensuse.org/distribution/leap/$releasever/repo/oss/"; }.
  repos,

  # Also mandatory, same reasoning as the other targets' `releasever`.
  # openSUSE Leap's own convention, e.g. "15.6" (bare version, like
  # Fedora's -- not CentOS Stream's "N-stream").
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
