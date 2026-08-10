# Same real, sandboxed-apt mechanism as deb's resolver -- isolated
# Dir::State/Dir::Cache/sources.list under a temp dir, real GPG signature
# verification against the pinned Ubuntu archive keyring, following each
# dependency's direct Depends recursively into other library packages
# only. Pointed at the real Ubuntu archive for the base's own release
# instead of an arbitrary caller-supplied repo list.
{ lib, architecture, sourcesList, keyring }:
{ pkgs, deps }:
let
  depsFile = pkgs.writeText "snap-deps.json" (builtins.toJSON deps);
in
pkgs.writeShellApplication {
  name = "resolve-snap";
  runtimeInputs = [ pkgs.apt pkgs.gnupg pkgs.jq ];
  text = ''
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    mkdir -p "$WORK"/{etc/apt/sources.list.d,var/lib/apt/lists/partial,var/cache/apt/archives/partial,var/lib/dpkg}
    touch "$WORK/var/lib/dpkg/status"
    cp ${sourcesList} "$WORK/etc/apt/sources.list"

    APT_OPTS=(
      -o Dir::Etc::sourcelist="$WORK/etc/apt/sources.list"
      -o Dir::Etc::sourceparts="$WORK/etc/apt/sources.list.d"
      -o Dir::State::Lists="$WORK/var/lib/apt/lists"
      -o Dir::Cache::Archives="$WORK/var/cache/apt/archives"
      -o Dir::State::status="$WORK/var/lib/dpkg/status"
      -o Dir::Etc::Trusted=${keyring}
      -o Dir::Etc::TrustedParts=/nonexistent
      -o APT::Architecture=${architecture}
      -o APT::Architectures::=${architecture}
    )

    apt-get "''${APT_OPTS[@]}" update >&2

    EXCLUDE_RE='^(libc6|libc6-dev|libc-dev|libc-bin|libgcc-s[0-9]*|libstdc\+\+[0-9]*|gcc-[0-9]+-base)$'

    show_pkg() {
      apt-cache "''${APT_OPTS[@]}" show "$1" 2>/dev/null | awk 'BEGIN{RS=""} NR==1'
    }

    parse_dep_names() {
      local depends="$1"
      echo "$depends" | tr ',' '\n' | while read -r group; do
        first_alt=$(echo "$group" | cut -d'|' -f1)
        name=$(echo "$first_alt" | sed -E 's/\(.*\)//; s/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -n "$name" ] && echo "$name"
      done
    }

    declare -A VISITED
    PACKAGES_JSON='[]'

    resolve_closure() {
      local name="$1" version="''${2:-}" is_top="''${3:-0}"
      local spec="$name"
      [ -n "$version" ] && spec="$name=$version"

      if [[ -n "''${VISITED[$name]:-}" ]]; then return; fi
      VISITED[$name]=1

      local stanza actual_version depends section
      stanza=$(show_pkg "$spec")
      if [ -z "$stanza" ]; then
        echo "nixothea snap target: package not found: $spec" >&2
        exit 1
      fi
      actual_version=$(echo "$stanza" | grep -m1 "^Version:" | cut -d' ' -f2-)
      depends=$(echo "$stanza" | grep -m1 "^Depends:" | cut -d' ' -f2- || true)
      section=$(echo "$stanza" | grep -m1 "^Section:" | cut -d' ' -f2-)

      if [ "$is_top" != "1" ]; then
        if [[ "$name" =~ $EXCLUDE_RE ]]; then return; fi
        if [[ "$section" != "libs" && "$section" != "libdevel" ]]; then return; fi
      fi

      local uri_line url sha256
      uri_line=$(apt-get "''${APT_OPTS[@]}" --print-uris download "$name=$actual_version" 2>/dev/null | grep "^'http" || true)
      if [ -z "$uri_line" ]; then
        echo "nixothea snap target: could not resolve download URI for $name=$actual_version" >&2
        exit 1
      fi
      url=$(echo "$uri_line" | sed -E "s/^'([^']+)'.*/\1/")
      # Not read from --print-uris' own hash field (deb.nix's approach,
      # copied here initially) -- verified empirically that real Ubuntu
      # apt doesn't reliably print a SHA256 there (it printed SHA512
      # instead for a real package during testing, leaving this silently
      # empty). The package's own show stanza always carries a real
      # SHA256 field regardless, so read it from there.
      sha256=$(echo "$stanza" | grep -m1 "^SHA256:" | cut -d' ' -f2-)
      if [ -z "$sha256" ]; then
        echo "nixothea snap target: no SHA256 for $name=$actual_version (repo may not publish SHA256 checksums)" >&2
        exit 1
      fi

      PACKAGES_JSON=$(jq -n --argjson prev "$PACKAGES_JSON" --arg name "$name" --arg version "$actual_version" --arg url "$url" --arg sha256 "$sha256" --arg section "$section" \
        '$prev + [{name: $name, version: $version, url: $url, sha256: $sha256, section: $section}]')

      if [ -n "$depends" ]; then
        while read -r depname; do
          [ -z "$depname" ] && continue
          resolve_closure "$depname" "" 0
        done < <(parse_dep_names "$depends")
      fi
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
