# A constructor: `nixothea.targets.dnfOpensuse { repos = [...]; releasever = "15.6"; }`
# returns a target that builds a real .rpm against openSUSE Leap. Named
# "dnf" rather than "zypper" for an honest reason: neither zypper nor
# libzypp are packaged in nixpkgs, so there's no zypper binary to reuse.
# openSUSE's repos publish standard createrepo-format repodata though
# (repomd.xml/primary.xml.gz -- the same schema dnf/libsolv already read),
# so dnf5 can query and download from them directly, verified empirically
# against a real Leap 15.6 repo. Same idea as dnf-fedora.nix/dnf-rhel.nix
# otherwise -- see dnf-fedora.nix's comments for the parts that are
# identical (whatprovides-based Requires resolution, Provides:-based
# library classification, AutoReqProv: no, etc.).
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  # Bootstraps trust for `resolve`'s dnf5 calls: pinned by hash, same
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
  suseGpgKeyring = pkgs.fetchurl {
    url = "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x70af9e8139db7c82";
    name = "suse-package-signing-key.asc";
    hash = "sha256-y3+MLqx7rfjHUgpERxUgjjDXIiSz+q2QYNg6QQSo+Z0=";
  };

  # Same as the other dnf-based targets: bintools-wrapper's setup hook
  # skips `$dep/lib64` when it's a symlink, so the convenience symlink
  # always has to be named `lib`.
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
  # a Nix store glibc path, and confirmed with a real bwrap sandbox with
  # no /nix visible that this makes the built .rpm's binary fail to
  # execute at all on a real target machine (`execvp: No such file or
  # directory`, not some fallback) -- completely independent of whether
  # Requires: is satisfied.
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
  # Where to resolve/fetch packages from -- mandatory, no default, same
  # reasoning as the other targets' `repos`. Each entry becomes one dnf
  # repo stanza, e.g. { id = "oss"; baseurl =
  # "https://download.opensuse.org/distribution/leap/$releasever/repo/oss/"; }.
  repos,

  # Also mandatory, same reasoning as the other targets' `releasever`.
  # openSUSE Leap's own convention, e.g. "15.6" (bare version, like
  # Fedora's -- not CentOS Stream's "N-stream").
  releasever,

  architecture ? "x86_64",

  vendor ? null,
  license ? "unspecified",
  group ? "Unspecified",
}:
let
  libDir = archLibDirs.${architecture} or
    (throw "nixothea dnfOpensuse target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames archLibDirs)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea dnfOpensuse target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");

  reposFile = pkgs.writeText "nixothea.repo" (lib.concatMapStringsSep "\n\n"
    (repo: ''
      [${repo.id}]
      name=${repo.id}
      baseurl=${repo.baseurl}
      enabled=1
      gpgcheck=1
      repo_gpgcheck=0
      gpgkey=file://${suseGpgKeyring}
    '')
    repos);
in
mkTarget {
  inherit lib;

  # See dnf-fedora.nix's `resolve` for the full rationale (identical
  # logic). EXCLUDE_RE differs from Fedora/RHEL: openSUSE's base-toolchain
  # package names are more granular (verified empirically) --
  # `libgcc_s1`/`libstdc++6` instead of `libgcc`/`libstdc++`, plus
  # per-gcc-version variants (`libstdc++6-gcc12` etc.) that a devel
  # package's Requires never actually names directly (it names the bare
  # soname capability, which resolves to the unversioned base package), so
  # only the unversioned names need excluding.
  resolve = { pkgs, deps }:
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

        rpmkeys --dbpath="$WORK/rpmdb" --import ${suseGpgKeyring} >&2

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
    };

  # Same as the other dnf-based targets: no /lib -> /usr/lib merge or
  # symlink fixup needed (verified empirically -- openSUSE Leap is
  # merged-usr with relative symlinks too).
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
      passthru = { rpmPackages = entry.packages; };
    };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        allRpmPackages = builtins.attrValues (builtins.listToAttrs
          (map (p: { inherit (p) name; value = p; })
            (lib.concatMap (d: d.rpmPackages) (dependencyDeps ++ collected.dependencies))));

        runtimeRpmPackages = lib.filter (p: p.kind != "devel") allRpmPackages;
        requiresLine = lib.concatMapStringsSep ", " (p: "${p.name} = ${p.evr}") runtimeRpmPackages;

        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        description = args.meta.description or "";

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
        # `interpreters` above.
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
      throw "nixothea dnfOpensuse target: unknown role ${role}";
}
