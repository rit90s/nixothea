# Bootstraps trust for resolver.nix's dnf5 calls: pinned by hash, same
# pattern as dnf-fedora's fedora-gpg-keys. Unlike Fedora, this key isn't
# versioned per release -- verified empirically that CentOS Stream 9's and
# 10's centos-gpg-keys packages ship the exact same OpenPGP key (same
# fingerprint, just filed under a different name --
# `RPM-GPG-KEY-centosofficial` on 9, `RPM-GPG-KEY-centosofficial-SHA256`
# on 10), so pinning the one below covers both regardless of which
# `releasever` the caller configures.
{ pkgs }:
let
  centosGpgKeysRpm = pkgs.fetchurl {
    url = "https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-10.0-23.el10.noarch.rpm";
    hash = "sha256-8iMUP8ANlWN22fY2GlOAN+c4pGmtedTYJVXpmjB8UQ8=";
  };
in
pkgs.runCommand "centos-gpg-keyring.asc"
  { nativeBuildInputs = [ pkgs.rpm pkgs.cpio ]; } ''
    mkdir extracted && cd extracted
    rpm2cpio ${centosGpgKeysRpm} | cpio -idm --quiet
    cat etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial-SHA256 > $out
  ''
