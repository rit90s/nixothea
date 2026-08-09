# A constructor: `nixothea.targets.dnfRhel { repos = [...]; releasever = "10-stream"; }`
# returns a target that builds a real .rpm against the RHEL family, using
# CentOS Stream as the concrete distro (freely accessible without a
# subscription, unlike RHEL itself; Rocky/Alma would need their own pinned
# keyring, since they don't share CentOS Stream's signing key). Same idea
# as dnf-fedora.nix -- see that file's comments for the parts that are
# identical (whatprovides-based Requires resolution, Provides:-based
# library classification, AutoReqProv: no, etc.) -- only the differences
# specific to CentOS Stream are called out here.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  # Bootstraps trust for `resolve`'s dnf5 calls: pinned by hash, same
  # pattern as dnf-fedora.nix's fedora-gpg-keys. Unlike Fedora, this key
  # isn't versioned per release -- verified empirically that CentOS
  # Stream 9's and 10's centos-gpg-keys packages ship the exact same
  # OpenPGP key (same fingerprint, just filed under a different name --
  # `RPM-GPG-KEY-centosofficial` on 9, `RPM-GPG-KEY-centosofficial-SHA256`
  # on 10), so pinning the one below covers both regardless of which
  # `releasever` the caller configures.
  centosGpgKeysRpm = pkgs.fetchurl {
    url = "https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-10.0-23.el10.noarch.rpm";
    hash = "sha256-8iMUP8ANlWN22fY2GlOAN+c4pGmtedTYJVXpmjB8UQ8=";
  };
  centosGpgKeyring = pkgs.runCommand "centos-gpg-keyring.asc"
    { nativeBuildInputs = [ pkgs.rpm pkgs.cpio ]; } ''
      mkdir extracted && cd extracted
      rpm2cpio ${centosGpgKeysRpm} | cpio -idm --quiet
      cat etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial-SHA256 > $out
    '';

  # Same as dnf-fedora.nix: bintools-wrapper's setup hook skips
  # `$dep/lib64` when it's a symlink, so the convenience symlink always
  # has to be named `lib`.
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
  # reasoning as deb's `repos` and dnf-fedora's `repos`. Each entry becomes
  # one dnf repo stanza, e.g. { id = "baseos"; baseurl =
  # "https://mirror.stream.centos.org/$releasever/BaseOS/$basearch/os/"; }
  # -- CentOS Stream splits runtime packages into BaseOS and most -devel
  # packages into AppStream, so most callers will want both.
  repos,

  # Also mandatory, same reasoning as dnf-fedora's `releasever`. Note this
  # is CentOS Stream's own directory-name convention, e.g. "10-stream" or
  # "9-stream" -- not a bare number like Fedora's "44".
  releasever,

  architecture ? "x86_64",

  vendor ? null,
  license ? "unspecified",
  group ? "Unspecified",
}:
let
  libDir = archLibDirs.${architecture} or
    (throw "nixothea dnfRhel target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames archLibDirs)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea dnfRhel target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");

  reposFile = pkgs.writeText "nixothea.repo" (lib.concatMapStringsSep "\n\n"
    (repo: ''
      [${repo.id}]
      name=${repo.id}
      baseurl=${repo.baseurl}
      enabled=1
      gpgcheck=1
      repo_gpgcheck=0
      gpgkey=file://${centosGpgKeyring}
    '')
    repos);
in
mkTarget {
  inherit lib;

  # See dnf-fedora.nix's `resolve` for the full rationale (identical
  # logic: whatprovides-based capability resolution, Provides:-based
  # library classification, base-toolchain exclude list, download +
  # rpmkeys --checksig + sha256 pinning). Verified empirically that
  # CentOS Stream's package names for the base toolchain match Fedora's
  # exactly (glibc, glibc-devel, libgcc, libstdc++, libstdc++-devel, gcc),
  # so the same EXCLUDE_RE applies unchanged. Unlike Fedora's single-version
  # "Everything/os" tree, CentOS Stream's repos accumulate multiple builds
  # of the same package under one release, so `--latest-limit=1` (already
  # used below) is what keeps `query_nevra` unambiguous here, not just a
  # nicety.
  resolve = { pkgs, deps }:
    let
      depsFile = pkgs.writeText "dnf-rhel-deps.json" (builtins.toJSON deps);
    in
    pkgs.writeShellApplication {
      name = "resolve-dnf-rhel";
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

        rpmkeys --dbpath="$WORK/rpmdb" --import ${centosGpgKeyring} >&2

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
            echo "nixothea dnfRhel target: package not found: $name''${pin:+=$pin}" >&2
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
            echo "nixothea dnfRhel target: download failed for $spec" >&2
            exit 1
          fi

          if ! rpmkeys --dbpath="$WORK/rpmdb" --checksig "$rpmfile" | grep -q "digests signatures OK"; then
            echo "nixothea dnfRhel target: signature verification failed for $spec" >&2
            exit 1
          fi

          local url sha256
          url=$(dnf5 "''${DNF_OPTS[@]}" download --url "$spec" 2>/dev/null | grep -m1 '^http')
          sha256=$(sha256sum "$rpmfile" | cut -d' ' -f1)
          if [ -z "$url" ]; then
            echo "nixothea dnfRhel target: could not resolve download URL for $spec" >&2
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

  # Same as dnf-fedora.nix: no /lib -> /usr/lib merge or symlink fixup
  # needed (verified empirically -- CentOS Stream 10 is merged-usr with
  # relative symlinks, same as Fedora).
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
      throw "nixothea dnfRhel target: unknown role ${role}";
}
