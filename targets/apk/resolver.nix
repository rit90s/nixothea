# Runs a sandboxed apk (isolated --root under a temp dir -- no system-wide
# effects, no root needed) against the configured repos, with real RSA
# signature verification against the pinned Alpine release key (see
# keyring.pkg.nix). Unlike deb.nix, there's no hand-rolled recursive
# Depends: walk needed here: `apk fetch -R` already resolves and downloads
# the *entire* transitive dependency closure in one real call (apk's own
# solver, not a re-implementation of it) -- so this just downloads, then
# reads each downloaded file's own embedded .PKGINFO back (name/version),
# rather than trying to regex-split them out of `<name>-<version>.apk`
# filenames, which is genuinely ambiguous (package names routinely contain
# digits and hyphens, e.g. "libcrypto3", "nghttp2-libs"). `musl` itself is
# excluded from the result, same reasoning as deb.nix excluding libc6:
# it's what builder.nix's interpreter-retarget assumes is already present
# on every real Alpine system, not something to bundle/extract.
# `entry.version`, if set, pins an exact version via apk's own
# `name=version` constraint syntax; otherwise whatever's current is used.
{ lib, architecture, repos, keyring }:
{ pkgs, deps }:
let
  depsFile = pkgs.writeText "apk-deps.json" (builtins.toJSON deps);
  repoArgs = lib.concatMapStringsSep " " (r: "-X ${lib.escapeShellArg r}") repos;
in
pkgs.writeShellApplication {
  name = "resolve-apk";
  runtimeInputs = [ pkgs.apk-tools pkgs.jq pkgs.gnutar ];
  text = ''
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    mkdir -p "$WORK/root" "$WORK/dl"

    APK_OPTS=(--no-cache --keys-dir ${keyring} --root "$WORK/root" --arch ${architecture})

    pkginfo_val() {
      tar xzO -f "$1" .PKGINFO 2>/dev/null | sed -n "s/^$2 = //p" | head -n1
    }

    OUT_JSON='{}'
    for logical_name in $(jq -r 'keys[]' ${depsFile}); do
      real_name=$(jq -r ".[\"$logical_name\"].name" ${depsFile})
      pin_version=$(jq -r ".[\"$logical_name\"].version // empty" ${depsFile})
      spec="$real_name"
      [ -n "$pin_version" ] && spec="$real_name=$pin_version"

      rm -rf "$WORK/dl" && mkdir -p "$WORK/dl"
      urls=$(apk fetch -R --url "''${APK_OPTS[@]}" ${repoArgs} -o "$WORK/dl" "$spec")

      PACKAGES_JSON='[]'
      while IFS= read -r url; do
        [ -z "$url" ] && continue
        file="$WORK/dl/''${url##*/}"
        [ -f "$file" ] || { echo "nixothea apk target: expected download missing: $file" >&2; exit 1; }

        name=$(pkginfo_val "$file" pkgname)
        [ "$name" = "musl" ] && continue

        version=$(pkginfo_val "$file" pkgver)
        sha256=$(sha256sum "$file" | cut -d' ' -f1)

        PACKAGES_JSON=$(jq -n --argjson prev "$PACKAGES_JSON" --arg name "$name" --arg version "$version" --arg url "$url" --arg sha256 "$sha256" \
          '$prev + [{name: $name, version: $version, url: $url, sha256: $sha256}]')
      done <<< "$urls"

      OUT_JSON=$(jq -n --argjson prev "$OUT_JSON" --arg logical "$logical_name" --arg name "$real_name" --argjson packages "$PACKAGES_JSON" \
        '$prev + {($logical): {name: $name, packages: $packages}}')
    done

    echo "$OUT_JSON"
  '';
}
