# Bootstraps trust for resolver.nix's apt-get calls: pinned by hash (like
# the AppImage runtime stub), not fetched fresh each time, so apt's own
# signature verification of the repo's Release file has something to
# check against without needing debian-archive-keyring packaged in
# nixpkgs (it isn't).
{ pkgs }:
let
  debianArchiveKeyringDeb = pkgs.fetchurl {
    url = "https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb";
    sha256 = "1b3z7kmsnmf05vi0bs4rpd4fglrdna57lwv80r4wli1i8j77g9wy";
  };
in
pkgs.runCommand "debian-archive-keyring.gpg"
  { nativeBuildInputs = [ pkgs.dpkg ]; } ''
    dpkg-deb -x ${debianArchiveKeyringDeb} extracted
    cp extracted/usr/share/keyrings/debian-archive-keyring.gpg $out
  ''
