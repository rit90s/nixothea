# Runs a sandboxed dnf5 (isolated installroot/cachedir under a temp dir --
# no system-wide effects, no root needed) against the configured repos.
# For each declared dependency, follows its *direct* Requires
# recursively: RPM Requires are capability strings (sonames, virtual
# provides, file paths), not package names, so each one is resolved to a
# providing package via `dnf5 repoquery --whatprovides` first. Only
# recurses into packages that are actually libraries: name ends with
# "-devel" (headers/static libs), or the package's own Provides: includes
# a `.so` soname (the real runtime library). Name-prefix heuristics like
# "starts with lib" don't hold in Fedora any more than deb's "starts with
# lib" held for zlib1g -- e.g. Fedora's own zlib runtime package is named
# `zlib-ng-compat`, no "lib" in sight, and Fedora deprecated the `Group`
# tag years ago so there's no deb-Section-style field to classify by
# either. Checking Provides: for a `.so` entry is what's actually
# reliable, since that's the exact capability a devel package's Requires
# names to pull it in. Never recurses into base-toolchain packages Nix's
# own stdenv already provides (glibc, libgcc, libstdc++ -- these *do*
# provide .so sonames or end in -devel, so need an explicit exclude on
# top, same as deb's gcc-*-base). Unlike deb (whose Release file is
# GPG-signed, so apt can trust the Packages manifest's published
# checksums without downloading anything), Fedora's ordinary repos don't
# sign their metadata -- trust lives in each RPM's own embedded signature
# instead, which can only be checked against the actual downloaded bytes.
# So every included package gets downloaded during resolve, checked with
# `rpmkeys --checksig` against the pinned fedora-gpg-keys keyring, and
# hashed for the lock file. `entry.version`, if set, pins an exact
# `name-evr` match; otherwise the latest candidate is used.
{ lib, releasever, architecture, reposFile, keyring }:
{ pkgs, deps }:
let
  depsFile = pkgs.writeText "dnf-fedora-deps.json" (builtins.toJSON deps);
in
pkgs.writeShellApplication {
  name = "resolve-dnf-fedora";
  runtimeInputs = [ pkgs.dnf5 pkgs.rpm pkgs.jq ];
  text = ''
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    mkdir -p "$WORK"/{root,cache,rpmdb,dl}
    cp ${reposFile} "$WORK/nixothea.repo"

    DNF_OPTS=(
      --installroot="$WORK/root"
      --setopt="reposdir=$WORK"
      --setopt="cachedir=$WORK/cache"
      --releasever=${releasever}
      --forcearch=${architecture}
    )

    rpmkeys --dbpath="$WORK/rpmdb" --import ${keyring} >&2

    EXCLUDE_RE='^(glibc|glibc-devel|glibc-common|glibc-headers|glibc-minimal-langpack|libgcc|libstdc\+\+|libstdc\+\+-devel|gcc)$'

    query_nevra() {
      local name="$1" pin="''${2:-}" out
      out=$(dnf5 "''${DNF_OPTS[@]}" repoquery --arch="${architecture},noarch" --latest-limit=1 --qf '%{name}|%{evr}|%{arch}\n' "$name" 2>/dev/null)
      if [ -n "$pin" ]; then
        out=$(echo "$out" | awk -F'|' -v v="$pin" '$2==v')
      fi
      echo "$out" | head -n1
    }

    declare -A VISITED
    PACKAGES_JSON='[]'

    resolve_closure() {
      local name="$1" pin="''${2:-}" is_top="''${3:-0}"

      if [[ -n "''${VISITED[$name]:-}" ]]; then return; fi
      VISITED[$name]=1

      if [ "$is_top" != "1" ] && [[ "$name" =~ $EXCLUDE_RE ]]; then return; fi

      local line nevra_name evr arch
      line=$(query_nevra "$name" "$pin")
      if [ -z "$line" ]; then
        echo "nixothea dnfFedora target: package not found: $name''${pin:+=$pin}" >&2
        exit 1
      fi
      IFS='|' read -r nevra_name evr arch <<<"$line"
      local spec="$nevra_name-$evr.$arch"

      local kind="runtime"
      if [[ "$nevra_name" == *-devel ]]; then
        kind="devel"
      elif [ "$is_top" != "1" ]; then
        # Not a top-level request and not a -devel package: only worth
        # pulling in if it actually provides a shared library soname
        # (see the big comment above for why name prefixes can't be
        # trusted here).
        if ! dnf5 "''${DNF_OPTS[@]}" repoquery --provides "$spec" 2>/dev/null | grep -q '\.so'; then
          return
        fi
      fi

      local dl="$WORK/dl/$nevra_name"
      mkdir -p "$dl"
      dnf5 "''${DNF_OPTS[@]}" download --destdir="$dl" "$spec" >&2
      local rpmfile
      rpmfile=$(find "$dl" -name '*.rpm' | head -n1)
      if [ -z "$rpmfile" ]; then
        echo "nixothea dnfFedora target: download failed for $spec" >&2
        exit 1
      fi

      if ! rpmkeys --dbpath="$WORK/rpmdb" --checksig "$rpmfile" | grep -q "digests signatures OK"; then
        echo "nixothea dnfFedora target: signature verification failed for $spec" >&2
        exit 1
      fi

      local url sha256
      url=$(dnf5 "''${DNF_OPTS[@]}" download --url "$spec" 2>/dev/null | grep -m1 '^http')
      sha256=$(sha256sum "$rpmfile" | cut -d' ' -f1)
      if [ -z "$url" ]; then
        echo "nixothea dnfFedora target: could not resolve download URL for $spec" >&2
        exit 1
      fi

      PACKAGES_JSON=$(jq -n --argjson prev "$PACKAGES_JSON" --arg name "$nevra_name" --arg evr "$evr" --arg arch "$arch" --arg url "$url" --arg sha256 "$sha256" --arg kind "$kind" \
        '$prev + [{name: $name, evr: $evr, arch: $arch, url: $url, sha256: $sha256, kind: $kind}]')

      local reqs
      reqs=$(dnf5 "''${DNF_OPTS[@]}" repoquery --requires "$spec" 2>/dev/null || true)
      while read -r cap; do
        [ -z "$cap" ] && continue
        [[ "$cap" == rpmlib\(* ]] && continue
        local provider
        provider=$(dnf5 "''${DNF_OPTS[@]}" repoquery --whatprovides "$cap" --qf '%{name}\n' 2>/dev/null | sort -u | head -n1)
        [ -z "$provider" ] && continue
        resolve_closure "$provider" "" 0
      done <<<"$reqs"
    }

    OUT_JSON='{}'
    for logical_name in $(jq -r 'keys[]' ${depsFile}); do
      real_name=$(jq -r ".[\"$logical_name\"].name" ${depsFile})
      pin_version=$(jq -r ".[\"$logical_name\"].version // empty" ${depsFile})

      PACKAGES_JSON='[]'
      declare -A VISITED=()
      resolve_closure "$real_name" "$pin_version" 1

      OUT_JSON=$(jq -n --argjson prev "$OUT_JSON" --arg logical "$logical_name" --arg name "$real_name" --argjson packages "$PACKAGES_JSON" \
        '$prev + {($logical): {name: $name, packages: $packages}}')
    done

    echo "$OUT_JSON"
  '';
}
