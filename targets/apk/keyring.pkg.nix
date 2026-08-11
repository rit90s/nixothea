# Bootstraps trust for resolver.nix's apk-fetch calls: pinned by hash
# (like the AppImage runtime stub), not fetched fresh each time, so apk's
# own signature verification of the repo's index/packages has something
# to check against without needing alpine-keys packaged in nixpkgs (it
# isn't). This is Alpine's current main "release" signing key, used
# across every currently-supported release branch (Alpine reuses one key
# across many releases rather than rotating per-version, unlike Debian's
# per-suite keys) -- verified against a real, live fetch+resolve of the
# v3.20/main repo. `apk --keys-dir` matches purely by filename (the
# `.SIGN.RSA.<name>` entry embedded in the index/package), so the
# `$out/<name>` layout below is load-bearing, not cosmetic.
{ pkgs }:
let
  keyName = "alpine-devel@lists.alpinelinux.org-6165ee59.rsa.pub";
  key = pkgs.fetchurl {
    url = "https://alpinelinux.org/keys/${keyName}";
    sha256 = "207e4696d3c05f7cb05966aee557307151f1f00217af4143c1bcaf33b8df733f";
  };
in
pkgs.runCommand "alpine-keys" { } ''
  mkdir -p $out
  cp ${key} "$out/${keyName}"
''
