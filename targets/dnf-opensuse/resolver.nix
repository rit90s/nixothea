# See dnf-fedora's resolver for the full rationale (identical logic).
# EXCLUDE_RE differs from Fedora/RHEL: openSUSE's base-toolchain package
# names are more granular (verified empirically) -- `libgcc_s1`/
# `libstdc++6` instead of `libgcc`/`libstdc++`, plus per-gcc-version
# variants (`libstdc++6-gcc12` etc.) that a devel package's Requires
# never actually names directly (it names the bare soname capability,
# which resolves to the unversioned base package), so only the
# unversioned names need excluding.
{ lib, releasever, architecture, reposFile, keyring }:
{ pkgs, deps }:
let
  depsFile = pkgs.writeText "dnf-opensuse-deps.json" (builtins.toJSON deps);
in
pkgs.writeShellApplication {
  name = "resolve-dnf-opensuse";
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

    EXCLUDE_RE='^(glibc|glibc-devel|libgcc_s1|libstdc\+\+6|libstdc\+\+-devel|gcc)$'

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
        echo "nixothea dnfOpensuse target: package not found: $name''${pin:+=$pin}" >&2
        exit 1
      fi
      IFS='|' read -r nevra_name evr arch <<<"$line"
      local spec="$nevra_name-$evr.$arch"

      local kind="runtime"
      if [[ "$nevra_name" == *-devel ]]; then
        kind="devel"
      elif [ "$is_top" != "1" ]; then
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
        echo "nixothea dnfOpensuse target: download failed for $spec" >&2
        exit 1
      fi

      if ! rpmkeys --dbpath="$WORK/rpmdb" --checksig "$rpmfile" | grep -q "digests signatures OK"; then
        echo "nixothea dnfOpensuse target: signature verification failed for $spec" >&2
        exit 1
      fi

      local url sha256
      url=$(dnf5 "''${DNF_OPTS[@]}" download --url "$spec" 2>/dev/null | grep -m1 '^http')
      sha256=$(sha256sum "$rpmfile" | cut -d' ' -f1)
      if [ -z "$url" ]; then
        echo "nixothea dnfOpensuse target: could not resolve download URL for $spec" >&2
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
