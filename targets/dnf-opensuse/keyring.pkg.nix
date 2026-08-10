# Bootstraps trust for resolver.nix's dnf5 calls: pinned by hash, same
# pattern as the other dnf-based targets. This is *not* the key that
# signs repomd.xml (that one, "openSUSE Project Signing Key", is a red
# herring here -- verified empirically that individual packages are
# actually signed by a separate build-service key). Fetched from a
# public keyserver since openSUSE doesn't ship a "-gpg-keys"-style
# package the way Fedora/CentOS do (checked: openSUSE-release's file
# list has no /etc/pki/rpm-gpg equivalent) -- reproducibility here comes
# from the pinned hash below, not from the source being SUSE
# infrastructure, so this is no less trustworthy than any other
# hash-pinned fetchurl. Verified this exact key's fingerprint
# (FEAB502539D846DB2C0961CA70AF9E8139DB7C82) actually validates a real
# downloaded package's signature before pinning it.
{ pkgs }:
pkgs.fetchurl {
  url = "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x70af9e8139db7c82";
  name = "suse-package-signing-key.asc";
  hash = "sha256-y3+MLqx7rfjHUgpERxUgjjDXIiSz+q2QYNg6QQSo+Z0=";
}
