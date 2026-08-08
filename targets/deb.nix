# A constructor: `nixothea.targets.deb { repos = [...]; }` returns a
# target that builds a real .deb, with runtime dependencies fetched as real
# .deb files and extracted during the build -- unlike aur, where a
# dependency is just metadata, here it has to be a real, linkable
# derivation, since the whole point is that the real Nix build (buildPhase
# etc) can actually compile/link against it, the way a real Debian build
# would. The same target implementation can be instantiated more than once
# under different names (e.g. `debian`/`ubuntu`, each with their own repos).
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  # Bootstraps trust for `resolve`'s apt-get calls: pinned by hash (like
  # the AppImage runtime stub), not fetched fresh each time, so apt's own
  # signature verification of the repo's Release file has something to
  # check against without needing debian-archive-keyring packaged in
  # nixpkgs (it isn't).
  debianArchiveKeyringDeb = pkgs.fetchurl {
    url = "https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb";
    sha256 = "1b3z7kmsnmf05vi0bs4rpd4fglrdna57lwv80r4wli1i8j77g9wy";
  };
  debianArchiveKeyring = pkgs.runCommand "debian-archive-keyring.gpg"
    { nativeBuildInputs = [ pkgs.dpkg ]; } ''
      dpkg-deb -x ${debianArchiveKeyringDeb} extracted
      cp extracted/usr/share/keyrings/debian-archive-keyring.gpg $out
    '';

  multiarchTriplets = {
    amd64 = "x86_64-linux-gnu";
    arm64 = "aarch64-linux-gnu";
    armhf = "arm-linux-gnueabihf";
    i386 = "i386-linux-gnu";
  };
in
{
  # Where to resolve/fetch packages from -- mandatory, no default, since
  # silently defaulting to some particular Debian mirror/suite is exactly
  # the kind of implicit choice a caller should have to make explicitly.
  # Each entry becomes one `deb <url> <suite> <components...>` sources.list
  # line, e.g. { url = "https://deb.debian.org/debian"; suite = "bookworm"; components = [ "main" ]; }.
  repos,

  architecture ? "amd64",

  maintainer ? null,
  section ? "misc",
  priority ? "optional",
}:
let
  multiarchTriplet = multiarchTriplets.${architecture} or
    (throw "nixothea deb target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames multiarchTriplets)})");

  sourcesList = pkgs.writeText "sources.list" (lib.concatMapStringsSep "\n"
    (repo: "deb ${repo.url} ${repo.suite} ${lib.concatStringsSep " " repo.components}")
    repos);
in
mkTarget {
  inherit lib;

  # Runs a sandboxed apt (isolated Dir::State/Dir::Cache/sources.list under
  # a temp dir -- no system-wide effects, no root needed) against the
  # configured repos, with real GPG signature verification against the
  # pinned debian-archive-keyring. For each declared dependency, follows
  # its *direct* Depends recursively, but only into other library packages
  # (Section: libs/libdevel -- far more reliable than name prefixes, e.g.
  # zlib1g doesn't start with "lib") and never into base-toolchain
  # packages Nix's own stdenv already provides (glibc, libgcc, libstdc++)
  # -- pulling those in would risk a real ABI mismatch, not just
  # redundancy. `entry.version`, if set, pins an exact version; otherwise
  # whatever the repo's current candidate is gets used.
  resolve = { pkgs, deps }:
    let
      depsFile = pkgs.writeText "deb-deps.json" (builtins.toJSON deps);
    in
    pkgs.writeShellApplication {
      name = "resolve-deb";
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
          -o Dir::Etc::Trusted=${debianArchiveKeyring}
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
            echo "nixothea deb target: package not found: $spec" >&2
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
            echo "nixothea deb target: could not resolve download URI for $name=$actual_version" >&2
            exit 1
          fi
          url=$(echo "$uri_line" | sed -E "s/^'([^']+)'.*/\1/")
          sha256=$(echo "$uri_line" | grep -oE 'SHA256:[a-f0-9]+' | cut -d: -f2)
          if [ -z "$sha256" ]; then
            echo "nixothea deb target: no SHA256 for $name=$actual_version (repo may not publish SHA256 checksums)" >&2
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
    };

  # Fetches each package in entry.packages (by the url+sha256 resolve
  # pinned -- a real, reproducible fixed-output fetch, no apt needed
  # again), extracts them all with dpkg-deb into one merged tree,
  # reproduces Debian's /lib->/usr/lib merge for packages that predate it
  # (e.g. zlib1g ships real files directly under lib/, not usr/lib/), fixes
  # up the absolute symlinks dpkg-deb preserves verbatim (which assume a
  # real root filesystem) to point inside the merged output instead, and
  # exposes top-level include/lib so Nix's own cc-wrapper auto-adds
  # -I/-L for this buildInput exactly like it would for any normal
  # nixpkgs library -- no custom setup-hook needed.
  nativeDerivationFactory = { pkgs, name, entry }:
    let
      fetched = map
        (p: pkgs.fetchurl { inherit (p) url sha256; name = "${p.name}.deb"; })
        entry.packages;
    in
    pkgs.stdenv.mkDerivation {
      pname = "${entry.name}-deb-extracted";
      version = (builtins.head entry.packages).version;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.dpkg ];
      # Foreign, already-built Debian binaries -- stripping/patchelf-ing
      # them would risk breaking whatever ABI expectations Debian's own
      # toolchain baked in, for no benefit (nothing here needs to conform
      # to Nix's own binary hygiene, only to link correctly).
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        mkdir -p $out
        ${lib.concatMapStringsSep "\n" (f: "dpkg-deb -x ${f} $out") fetched}

        for d in lib lib32 lib64 bin sbin; do
          if [ -d "$out/$d" ] && [ ! -L "$out/$d" ]; then
            mkdir -p "$out/usr/$d"
            cp -a "$out/$d/." "$out/usr/$d/"
            rm -rf "$out/$d"
          fi
        done

        find $out -type l | while read -r link; do
          target=$(readlink "$link")
          case "$target" in
            /lib/*|/lib32/*|/lib64/*|/bin/*|/sbin/*) ln -sfn "$out/usr$target" "$link" ;;
            /usr/*) ln -sfn "$out$target" "$link" ;;
          esac
        done

        [ -d "$out/usr/include" ] && ln -s "$out/usr/include" "$out/include"
        [ -d "$out/usr/lib/${multiarchTriplet}" ] && ln -s "$out/usr/lib/${multiarchTriplet}" "$out/lib"
        runHook postBuild
      '';
      dontInstall = true;
      # Not string-coercible (a list of attrsets), so it has to be
      # passthru rather than a normal derivation attr -- read back by
      # mkDerivation's root case below to build Depends:.
      passthru = { debPackages = entry.packages; };
    };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      # Already a real input of whatever consumed it (buildInputs
      # unwrapping already linked realDrv in for real) -- nothing further
      # to do until the root folds its payload in below.
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        allDebPackages = builtins.attrValues (builtins.listToAttrs
          (map (p: { inherit (p) name; value = p; })
            (lib.concatMap (d: d.debPackages) (dependencyDeps ++ collected.dependencies))));

        # -dev packages (headers, static libs, unversioned .so symlinks for
        # linking) are needed to build against, never at runtime -- a real
        # installed package shouldn't pull them in.
        runtimeDebPackages = lib.filter (p: p.section != "libdevel") allDebPackages;
        dependsLine = lib.concatMapStringsSep ", " (p: "${p.name} (= ${p.version})") runtimeDebPackages;

        # "One combined package", same as aur: every transitively-reachable
        # node's own real build output is folded into the same payload
        # tree as the root's, not split into separate interdependent .debs.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        controlFile = pkgs.writeText "control" (''
          Package: ${realDrv.pname}
          Version: ${realDrv.version}
          Section: ${section}
          Priority: ${priority}
          Architecture: ${architecture}
        '' + lib.optionalString (maintainer != null) "Maintainer: ${maintainer}\n"
        + lib.optionalString (runtimeDebPackages != [ ]) "Depends: ${dependsLine}\n"
        + "Description: ${args.meta.description or ""}\n");
      in
      pkgs.stdenv.mkDerivation {
        pname = "${realDrv.pname}-deb";
        version = realDrv.version;
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.dpkg ];
        buildPhase = ''
          runHook preBuild
          root=pkgroot
          mkdir -p "$root/DEBIAN" "$root/usr"
          ${lib.concatMapStringsSep "\n" (p: ''
            cp -a --no-preserve=ownership ${p}/. "$root/usr/"
            chmod -R u+w "$root/usr"
          '') allPayloads}
          cp ${controlFile} "$root/DEBIAN/control"
          dpkg-deb --build --root-owner-group "$root" "${realDrv.pname}_${realDrv.version}_${architecture}.deb"
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp ./*.deb $out/
          runHook postInstall
        '';
      }
    else
      throw "nixothea deb target: unknown role ${role}";
}
