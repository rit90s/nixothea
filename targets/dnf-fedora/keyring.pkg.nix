# Bootstraps trust for resolver.nix's dnf5 calls: pinned by hash (like the
# AppImage runtime stub and deb's debian-archive-keyring), not fetched
# fresh each time. fedora-gpg-keys ships every Fedora signing key from
# every release ever made (7 through rawhide) in one file -- importing
# the whole thing fails outright, since rpm 4.20's stricter OpenPGP
# policy engine rejects several of the decade-plus-old ones ("no binding
# signature at time") and `rpmkeys --import` aborts on the first bad key.
# Only the keys matching the caller's own `releasever` are extracted
# below, which is also just correct: it's what Fedora's own fedora.repo
# points `gpgkey=` at (.../RPM-GPG-KEY-fedora-$releasever-$basearch).
{ pkgs, releasever }:
let
  fedoraGpgKeysRpm = pkgs.fetchurl {
    url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/Packages/f/fedora-gpg-keys-44-1.noarch.rpm";
    hash = "sha256-WGYxRFy0NBKvgSWvccRNPsooUfB0FUqBCT+uxlFNrF8=";
  };
in
pkgs.runCommand "fedora-gpg-keyring-${releasever}.asc"
  { nativeBuildInputs = [ pkgs.rpm pkgs.cpio ]; } ''
    mkdir extracted && cd extracted
    rpm2cpio ${fedoraGpgKeysRpm} | cpio -idm --quiet
    cat etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${releasever}-* > $out
  ''
