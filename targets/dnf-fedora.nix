# A constructor: `nixothea.targets.dnfFedora { repos = [...]; releasever = "44"; }`
# returns a target that builds a real .rpm, with runtime dependencies
# fetched as real .rpm files and extracted during the build -- same idea as
# deb, adapted to dnf5/rpm. Specific to Fedora: the GPG keyring below is
# pinned from Fedora's own fedora-gpg-keys package, so this target can't
# just be re-instantiated under a different name to target a different
# RPM distro (see dnf-rhel.nix and dnf-opensuse.nix for those -- each
# needs its own keyring).
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  # Bootstraps trust for `resolve`'s dnf5 calls: pinned by hash (like the
  # AppImage runtime stub and deb's debian-archive-keyring), not fetched
  # fresh each time. fedora-gpg-keys ships every Fedora signing key from
  # every release ever made (7 through rawhide) in one file -- importing
  # the whole thing fails outright, since rpm 4.20's stricter OpenPGP
  # policy engine rejects several of the decade-plus-old ones ("no binding
  # signature at time") and `rpmkeys --import` aborts on the first bad key.
  # Only the keys matching the caller's own `releasever` are extracted
  # below, which is also just correct: it's what Fedora's own fedora.repo
  # points `gpgkey=` at (.../RPM-GPG-KEY-fedora-$releasever-$basearch).
  fedoraGpgKeysRpm = pkgs.fetchurl {
    url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/Packages/f/fedora-gpg-keys-44-1.noarch.rpm";
    hash = "sha256-WGYxRFy0NBKvgSWvccRNPsooUfB0FUqBCT+uxlFNrF8=";
  };

  # Nix's bintools-wrapper setup hook adds `-L$dep/lib64` (skipped if it's a
  # symlink!) and `-L$dep/lib` (symlink is fine, just needs to glob-match
  # lib*) -- so the convenience symlink below always has to be named `lib`,
  # never `lib64`, regardless of which real directory it points at.
  archLibDirs = {
    x86_64 = "lib64";
    aarch64 = "lib64";
    ppc64le = "lib64";
    s390x = "lib64";
    i686 = "lib";
    armv7hl = "lib";
  };

  # Standard glibc dynamic-linker install path per architecture -- what
  # the final .rpm's own binaries get patched to (see the patchelf pass
  # in mkDerivation's root case below). Verified this isn't optional: a
  # binary compiled by Nix's stdenv has its ELF interpreter hardcoded to
  # a Nix store glibc path (`readelf -p .interp` on a built binary shows
  # `/nix/store/...-glibc-.../ld-linux-x86-64.so.2`), and confirmed with a
  # real bwrap sandbox with no /nix visible that this makes the built
  # .rpm's binary fail to execute at all on a real target machine
  # (`execvp: No such file or directory`, not some fallback) --
  # completely independent of whether Requires: is satisfied.
  interpreters = {
    x86_64 = "/lib64/ld-linux-x86-64.so.2";
    aarch64 = "/lib/ld-linux-aarch64.so.1";
    ppc64le = "/lib64/ld64.so.2";
    s390x = "/lib/ld64.so.1";
    i686 = "/lib/ld-linux.so.2";
    armv7hl = "/lib/ld-linux-armhf.so.3";
  };
in
{
  # Where to resolve/fetch packages from -- mandatory, no default, for the
  # same reason as deb's `repos`: silently defaulting to some particular
  # Fedora mirror is an implicit choice a caller should have to make
  # explicitly. Each entry becomes one dnf repo stanza, e.g.
  # { id = "fedora"; baseurl = "https://dl.fedoraproject.org/pub/fedora/linux/releases/$releasever/Everything/$basearch/os/"; }.
  repos,

  # Also mandatory, for the same reason: which Fedora release's package set
  # to resolve against is exactly the kind of implicit choice that
  # shouldn't have a silent default.
  releasever,

  architecture ? "x86_64",

  vendor ? null,
  license ? "unspecified",
  group ? "Unspecified",
}:
let
  libDir = archLibDirs.${architecture} or
    (throw "nixothea dnfFedora target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames archLibDirs)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea dnfFedora target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");

  fedoraGpgKeyring = pkgs.runCommand "fedora-gpg-keyring-${releasever}.asc"
    { nativeBuildInputs = [ pkgs.rpm pkgs.cpio ]; } ''
      mkdir extracted && cd extracted
      rpm2cpio ${fedoraGpgKeysRpm} | cpio -idm --quiet
      cat etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${releasever}-* > $out
    '';

  reposFile = pkgs.writeText "nixothea.repo" (lib.concatMapStringsSep "\n\n"
    (repo: ''
      [${repo.id}]
      name=${repo.id}
      baseurl=${repo.baseurl}
      enabled=1
      gpgcheck=1
      repo_gpgcheck=0
      gpgkey=file://${fedoraGpgKeyring}
    '')
    repos);
in
mkTarget {
  inherit lib;

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
  resolve = { pkgs, deps }:
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

        rpmkeys --dbpath="$WORK/rpmdb" --import ${fedoraGpgKeyring} >&2

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
            # (see the big comment on `resolve` above for why name
            # prefixes can't be trusted here).
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
    };

  # Fetches each package in entry.packages (by the url+sha256 resolve
  # pinned -- a real, reproducible fixed-output fetch, no dnf needed again)
  # and extracts them all with rpm2cpio into one merged tree. Unlike deb,
  # no /lib -> /usr/lib merge is needed: Fedora completed its usrmerge
  # years ago, so every file in a modern Fedora rpm already lives under
  # usr/. Also unlike deb, no symlink-target fixup is needed: Fedora
  # packaging guidelines require relative symlinks (verified empirically --
  # rpmlint would flag an absolute one), so nothing here points outside the
  # extracted tree. Exposes top-level include/lib so Nix's own
  # bintools-wrapper auto-adds -L for this buildInput exactly like it would
  # for any normal nixpkgs library -- no custom setup-hook needed.
  nativeDerivationFactory = { pkgs, name, entry }:
    let
      fetched = map
        (p: pkgs.fetchurl { inherit (p) url sha256; name = "${p.name}.rpm"; })
        entry.packages;
    in
    pkgs.stdenv.mkDerivation {
      pname = "${entry.name}-rpm-extracted";
      version = (builtins.head entry.packages).evr;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.rpm pkgs.cpio ];
      # Foreign, already-built Fedora binaries -- stripping/patchelf-ing
      # them would risk breaking whatever ABI expectations Fedora's own
      # toolchain baked in, for no benefit.
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        mkdir -p $out
        ${lib.concatMapStringsSep "\n" (f: "(cd $out && rpm2cpio ${f} | cpio -idm --quiet)") fetched}
        [ -d "$out/usr/include" ] && ln -s "$out/usr/include" "$out/include"
        [ -d "$out/usr/${libDir}" ] && ln -s "$out/usr/${libDir}" "$out/lib"
        runHook postBuild
      '';
      dontInstall = true;
      # Not string-coercible (a list of attrsets), so it has to be
      # passthru rather than a normal derivation attr -- read back by
      # mkDerivation's root case below to build Requires:.
      passthru = { rpmPackages = entry.packages; };
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

        allRpmPackages = builtins.attrValues (builtins.listToAttrs
          (map (p: { inherit (p) name; value = p; })
            (lib.concatMap (d: d.rpmPackages) (dependencyDeps ++ collected.dependencies))));

        # -devel packages (headers, static libs, unversioned .so symlinks
        # for linking) are needed to build against, never at runtime -- a
        # real installed package shouldn't pull them in.
        runtimeRpmPackages = lib.filter (p: p.kind != "devel") allRpmPackages;
        requiresLine = lib.concatMapStringsSep ", " (p: "${p.name} = ${p.evr}") runtimeRpmPackages;

        # "One combined package", same as aur/deb: every
        # transitively-reachable node's own real build output is folded
        # into the same payload tree as the root's, not split into
        # separate interdependent .rpms.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        description = args.meta.description or "";

        # AutoReqProv is off because rpmbuild's automatic dependency
        # scanner runs ldd/rpmdeps against the packaged binaries expecting
        # a normal system layout -- against Nix-produced binaries (Nix
        # store RPATHs, foreign extracted-.rpm libraries) it would either
        # choke or fabricate bogus Requires/Provides. Requires: is instead
        # built entirely from what resolve already verified above.
        # debug_package/_build_id_links are disabled since there's no
        # source here for rpmbuild to generate a debuginfo package from.
        specFile = pkgs.writeText "${realDrv.pname}.spec" (''
          Name: ${realDrv.pname}
          Version: ${realDrv.version}
          Release: 1
          Summary: ${description}
          License: ${license}
          Group: ${group}
          BuildArch: ${architecture}
          AutoReqProv: no
        '' + lib.optionalString (vendor != null) "Vendor: ${vendor}\n"
        + lib.optionalString (runtimeRpmPackages != [ ]) "Requires: ${requiresLine}\n"
        + ''

          %global debug_package %{nil}
          %global _build_id_links none

          %description
          ${description}

          %install
          mkdir -p %{buildroot}/usr
        '' + lib.concatMapStringsSep "\n" (p: ''
          cp -a --no-preserve=ownership ${p}/. "%{buildroot}/usr/"
          chmod -R u+w "%{buildroot}/usr"
        '') allPayloads
        + ''

          find %{buildroot}/usr -type f | while read -r f; do
            if patchelf --print-rpath "$f" >/dev/null 2>&1; then
              patchelf --remove-rpath "$f" || true
              if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
                patchelf --set-interpreter "${targetInterpreter}" "$f"
              fi
            fi
          done

          %files
          /usr
        '');
      in
      pkgs.stdenv.mkDerivation {
        pname = "${realDrv.pname}-rpm";
        version = realDrv.version;
        dontUnpack = true;
        # patchelf: retargets our own built binaries from Nix's dynamic
        # linker to the real target system's, and drops the Nix-store
        # RPATH entries bintools-wrapper added for buildInputs -- see
        # `interpreters` above for why this isn't optional. Left
        # untouched: the extracted third-party .rpm payloads never enter
        # this tree (only allPayloads -- our own realDrv/nested-node
        # outputs -- do), so nothing here is foreign toolchain-built
        # content.
        nativeBuildInputs = [ pkgs.rpm pkgs.patchelf ];
        buildPhase = ''
          runHook preBuild
          mkdir -p rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} rpmdb rpmtmp buildroot
          HOME=$PWD rpmbuild \
            --define "_topdir $PWD/rpmbuild" \
            --define "_dbpath $PWD/rpmdb" \
            --define "_tmppath $PWD/rpmtmp" \
            --buildroot "$PWD/buildroot" \
            -bb ${specFile}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          find rpmbuild/RPMS -name '*.rpm' -exec cp {} $out/ \;
          runHook postInstall
        '';
      }
    else
      throw "nixothea dnfFedora target: unknown role ${role}";
}
