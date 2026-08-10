# Bootstraps trust for resolver.nix's apt-get calls, same idea as deb's
# debian-archive-keyring: pinned by hash against the real archive,
# verified by hand (`dpkg-deb -c` against the real fetched .deb) that
# this is the real path apt itself expects.
{ pkgs }:
let
  ubuntuArchiveKeyringDeb = pkgs.fetchurl {
    url = "http://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/ubuntu-keyring_2023.11.28.1_all.deb";
    sha256 = "1a5qml8h6br6xcl6yn427y1h9ivh6xhng9z9500axk2kb2ql7pin";
  };
in
pkgs.runCommand "ubuntu-archive-keyring.gpg"
  { nativeBuildInputs = [ pkgs.dpkg ]; } ''
    dpkg-deb -x ${ubuntuArchiveKeyringDeb} extracted
    cp extracted/usr/share/keyrings/ubuntu-archive-keyring.gpg $out
  ''
