# A constructor: `nixothea.targets.snap { }` returns a target that
# produces a real, pre-built Snap package tree (a `snap/snapcraft.yaml`
# plus its own local `payload/` directory) -- unlike this target's first
# version, this one does a real Nix-level compile, the same as
# `deb.nix`/`dnf-*.nix`/`windowsExe`/`windowsMsi`, not the
# `aur`/`homebrew`/`flatpak` "recipe only, the real compile happens
# client-side" style. `snapcraft --destructive-mode` (or a real managed
# build) still has to run to actually pack the `.snap`, but its only job
# is copying already-built files into place (`plugin: dump`) -- no
# compiling, no live `apt` fetch, at `snapcraft`-build time at all.
#
# Real background this design relies on (verified empirically against a
# real Ubuntu 24.04 qemu/KVM VM, no `/nix` visible, real `snapd`): a
# strict-confinement snap's app process runs inside a mount namespace
# where the *base* snap (e.g. `core24` -- a minimal real Ubuntu userspace)
# is mounted at the standard absolute FHS paths (a real
# `/lib64/ld-linux-x86-64.so.2`, a real
# `/usr/lib/x86_64-linux-gnu/libc.so.6`, ...), with `$SNAP` layered on
# top. A normally-linked Ubuntu binary's hardcoded ELF interpreter just
# resolves correctly against that -- no patchelf needed for *that* part,
# unlike `appimage.nix` (which can't assume any particular target
# filesystem exists at all) but very much like `deb.nix` (which relies on
# the target Debian machine's own real glibc). The one thing genuinely
# different from `deb.nix`: a Nix-built binary's interpreter is a
# `/nix/store/...` path, which the sandbox's mount namespace simply
# doesn't contain (ENOENT, not an AppArmor denial) -- so it still needs
# patchelf-ing to the base's real, known interpreter path, the same idea
# as `deb.nix`'s own `interpreters` map, just pointed at the base snap's
# Ubuntu release instead of an arbitrary caller-supplied `repos`.
#
# The other real, load-bearing difference from `deb.nix`: a `.deb`'s
# runtime dependencies are satisfied by `Depends:` -- the *target
# machine's own* `apt` installs them separately, from the same repo, at
# package-install time. A strict-confinement snap has no equivalent:
# nothing outside `$SNAP`/the base/a connected content-interface snap is
# visible to it at all, so there is no later "apt install" step to lean
# on. Every runtime library a declared dependency provides has to be
# bundled directly into this snap's own payload -- not just declared and
# trusted the way `deb.nix`'s `Depends:` line can get away with. Verified
# empirically end to end (real `stage-packages`-based predecessor test,
# then this real-bundling redesign): `snapd` sets a default
# `LD_LIBRARY_PATH` for strict-confinement apps covering
# `$SNAP/usr/lib/<triplet>`, so a bundled `.so` at the normal Debian/
# Ubuntu path is found automatically -- no explicit RPATH needed on our
# own built binaries either, just the interpreter fix above.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  licenseName = l: if builtins.isString l then l else (l.spdxId or l.shortName or null);
  licenseNames = l:
    if l == null then [ ]
    else if builtins.isList l then lib.filter (x: x != null) (map licenseName l)
    else lib.filter (x: x != null) [ (licenseName l) ];

  sanitizeSnapName = name:
    let
      lowered = lib.toLower name;
      dashed = lib.stringAsChars (c: if builtins.match "[a-z0-9]" c != null then c else "-") lowered;
      segments = lib.filter (s: builtins.isString s && s != "") (builtins.split "-+" dashed);
      joined = lib.concatStringsSep "-" segments;
    in
    if joined == "" then "x"
    else if builtins.match "[a-z].*" joined != null then joined
    else "x-" + joined;

  # Which real Ubuntu release a given Snap base corresponds to -- this is
  # inherent to what the base *means* (Canonical ties each one to a
  # specific Ubuntu release), not a caller choice the way `deb.nix`'s
  # `repos` is for arbitrary Debian derivatives.
  baseSuites = {
    core24 = "noble";
    core22 = "jammy";
    core20 = "focal";
    core18 = "bionic";
  };

  # Bootstraps trust for `resolve`'s apt-get calls, same idea as
  # deb.nix's debianArchiveKeyring: pinned by hash against the real
  # archive, verified by hand (`dpkg-deb -c` against the real fetched
  # .deb) that this is the real path apt itself expects.
  ubuntuArchiveKeyringDeb = pkgs.fetchurl {
    url = "http://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/ubuntu-keyring_2023.11.28.1_all.deb";
    sha256 = "1a5qml8h6br6xcl6yn427y1h9ivh6xhng9z9500axk2kb2ql7pin";
  };
  ubuntuArchiveKeyring = pkgs.runCommand "ubuntu-archive-keyring.gpg"
    { nativeBuildInputs = [ pkgs.dpkg ]; } ''
      dpkg-deb -x ${ubuntuArchiveKeyringDeb} extracted
      cp extracted/usr/share/keyrings/ubuntu-archive-keyring.gpg $out
    '';

  multiarchTriplets = {
    amd64 = "x86_64-linux-gnu";
    arm64 = "aarch64-linux-gnu";
    armhf = "arm-linux-gnueabihf";
    i386 = "i386-linux-gnu";
  };

  # Same real, standard FHS dynamic-linker paths as deb.nix's own
  # `interpreters` map -- the base snap provides a normal Ubuntu
  # userspace, so these are the same paths a real `.deb`'s binaries
  # expect on a real Debian-family machine.
  interpreters = {
    amd64 = "/lib64/ld-linux-x86-64.so.2";
    arm64 = "/lib/ld-linux-aarch64.so.1";
    armhf = "/lib/ld-linux-armhf.so.3";
    i386 = "/lib/ld-linux.so.2";
  };
in
{
  base ? "core24",
  confinement ? "strict",
  grade ? "stable",
  architecture ? "amd64",
}:
let
  suite = baseSuites.${base} or
    (throw "nixothea snap target: unsupported base '${base}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames baseSuites)})");

  multiarchTriplet = multiarchTriplets.${architecture} or
    (throw "nixothea snap target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames multiarchTriplets)})");

  targetInterpreter = interpreters.${architecture} or
    (throw "nixothea snap target: unsupported architecture '${architecture}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames interpreters)})");

  # Ubuntu's primary archive only carries amd64/i386 -- other
  # architectures are hosted on the separate, real "ports" archive. A
  # real Ubuntu infrastructure split, not a nixothea-specific choice.
  archiveHost =
    if builtins.elem architecture [ "amd64" "i386" ]
    then "http://archive.ubuntu.com/ubuntu"
    else "http://ports.ubuntu.com/ubuntu-ports";

  repoSuites = [ suite "${suite}-updates" "${suite}-security" ];
  components = [ "main" "universe" "restricted" "multiverse" ];

  sourcesList = pkgs.writeText "sources.list" (lib.concatMapStringsSep "\n"
    (s: "deb ${archiveHost} ${s} ${lib.concatStringsSep " " components}")
    repoSuites);
in
mkTarget {
  inherit lib;

  # Same real, sandboxed-apt mechanism as deb.nix's resolve -- isolated
  # Dir::State/Dir::Cache/sources.list under a temp dir, real GPG
  # signature verification against the pinned Ubuntu archive keyring,
  # following each dependency's direct Depends recursively into other
  # library packages only. Pointed at the real Ubuntu archive for the
  # base's own release instead of an arbitrary caller-supplied repo list.
  resolve = { pkgs, deps }:
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
          -o Dir::Etc::Trusted=${ubuntuArchiveKeyring}
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
          # copied here initially) -- verified empirically that real
          # Ubuntu apt doesn't reliably print a SHA256 there (it printed
          # SHA512 instead for a real package during testing, leaving
          # this silently empty). The package's own show stanza always
          # carries a real SHA256 field regardless, so read it from there.
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
    };

  # Same real fetch+dpkg-deb-extract mechanism as deb.nix's own
  # nativeDerivationFactory (see there for the full rationale of each
  # step) -- serves double duty here: used as a Nix buildInput so our own
  # code can genuinely compile/link against it (headers + linkable .so,
  # via the top-level include/lib symlinks Nix's cc-wrapper picks up
  # automatically), *and* its usr/ subtree gets bundled wholesale
  # straight into the final snap's own payload (see mkDerivation below) --
  # unlike deb.nix, which only ever needs it for the former.
  nativeDerivationFactory = { pkgs, name, entry }:
    let
      fetched = map
        (p: pkgs.fetchurl { inherit (p) url sha256; name = "${p.name}.deb"; })
        entry.packages;
    in
    pkgs.stdenv.mkDerivation {
      pname = "${entry.name}-snap-extracted";
      version = (builtins.head entry.packages).version;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.dpkg ];
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
    };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        allDependencyDerivations = dependencyDeps ++ collected.dependencies;

        # "One combined payload", the real-build equivalent of every other
        # target's nested-node merge: every transitively-reachable node's
        # own real build output, plus the root's own, copied into one
        # payload tree.
        allPayloads = [ realDrv ] ++ map (n: n.realDrv) collected.nodes;

        # Per-package, like mainProgram was in this target's first
        # version -- but optional now, not mandatory. Free to auto-detect
        # once this target always does a real Nix-level compile anyway
        # (same reasoning as appimage.nix's own auto-detect): the first
        # version had to make it mandatory specifically to avoid forcing
        # an unwanted build via "${realDrv}/bin" string interpolation,
        # which no longer applies once realDrv is always built for real
        # regardless.
        mainProgram = args.mainProgram or null;
        resolvedMainProgram =
          if mainProgram != null then
            mainProgram
          else if !(builtins.pathExists "${realDrv}/bin") then
            throw "nixothea snap target: ${realDrv.pname} has no bin/ directory -- set mainProgram explicitly"
          else
            let bins = builtins.attrNames (builtins.readDir "${realDrv}/bin");
            in
            if builtins.length bins == 1 then
              builtins.head bins
            else
              throw "nixothea snap target: ${realDrv.pname} ships ${toString (builtins.length bins)} binaries under bin/ -- set mainProgram explicitly";

        meta = args.meta or { };
        licenses = licenseNames (meta.license or null);
        licenseLine = if licenses == [ ] then null else lib.concatStringsSep " AND " licenses;

        snapPlugs = args.snapPlugs or [ ];
        snapName = sanitizeSnapName args.pname;

        payload = pkgs.stdenv.mkDerivation {
          pname = "${realDrv.pname}-snap-payload";
          version = realDrv.version;
          dontUnpack = true;
          # Unlike deb.nix (whose equivalent patching happens against a
          # throwaway build-dir, with only the final *packed* .deb blob
          # ever reaching $out, which Nix's fixupPhase can't see into),
          # this derivation's $out is the raw, loose payload tree itself --
          # so the default fixupPhase's own patchShebangs would rescan and
          # silently revert the interpreter-path fix below. Verified
          # empirically: without this, a script's shebang gets rewritten
          # back to the Nix store path patchShebangs originally set, right
          # after this buildPhase had just fixed it. Same reasoning as
          # appimage.nix's dontFixup: nothing here benefits an artifact
          # meant to run unmodified outside Nix anyway.
          dontFixup = true;
          nativeBuildInputs = [ pkgs.patchelf ];
          buildPhase = ''
            runHook preBuild
            mkdir -p payload

            ${lib.concatMapStringsSep "\n" (p: ''
              cp -a --no-preserve=ownership ${p}/. payload/
              chmod -R u+w payload
            '') allPayloads}

            # Retargets our own built binaries from Nix's dynamic linker to
            # the base snap's real one (see the header comment for why
            # this isn't optional), and drops the Nix-store RPATH entries
            # bintools-wrapper added for buildInputs -- once removed, the
            # loader falls through to snapd's own default LD_LIBRARY_PATH
            # for strict-confinement apps, which is exactly where the
            # bundled dependency libraries below end up. Left untouched:
            # the dependency-derivation content copied in next never
            # enters this loop (only allPayloads -- our own realDrv/
            # nested-node outputs -- do), so nothing here is foreign,
            # already-correctly-linked Ubuntu content.
            find payload -type f | while read -r f; do
              if patchelf --print-rpath "$f" >/dev/null 2>&1; then
                patchelf --remove-rpath "$f" || true
                if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
                  patchelf --set-interpreter "${targetInterpreter}" "$f"
                fi
              fi
            done

            # The exact same problem appimage.nix's AppRun generation had
            # to solve, for the exact same reason: realDrv's own (normal,
            # non-dontFixup'd) build already ran patchShebangs, which
            # rewrites e.g. a plain "#!/bin/sh" into an absolute
            # /nix/store/...-bash.../bin/sh -- a path the base snap's
            # mount namespace doesn't contain either. Verified empirically
            # (a real shell-script mainProgram genuinely ships this broken
            # shebang without this fix). patchShebangs preserves the
            # original interpreter's basename when it rewrites, so
            # reconstructing "/usr/bin/<basename>" is a real, correct
            # fix for the common case (a base snap's minimal Ubuntu
            # userspace has /usr/bin/sh, /usr/bin/bash) -- not a general
            # fix for an arbitrary interpreter the base doesn't ship
            # (e.g. python3), which would need appimage.nix's full
            # closure-bundling treatment to solve properly; out of scope
            # here, documented as a known gap. Only matches files whose
            # first line literally starts with "#!/nix/store/" -- an ELF
            # binary's first bytes are "\x7fELF", never "#!", so this
            # can't misfire on the ELF payloads the loop above handles.
            find payload -type f | while read -r f; do
              first_line=$(head -c 512 "$f" 2>/dev/null | head -n1)
              case "$first_line" in
                "#!${builtins.storeDir}"/*)
                  interp_path=''${first_line#\#!}
                  interp_bin=''${interp_path%% *}
                  interp_args=''${interp_path#"$interp_bin"}
                  interp_name=$(basename "$interp_bin")
                  sed -i "1s|.*|#!/usr/bin/$interp_name$interp_args|" "$f"
                  ;;
              esac
            done

            # Runtime library dependencies: bundled directly into the
            # payload, not just declared and trusted -- see the header
            # comment for why deb.nix's Depends:-only approach doesn't
            # carry over to a strict-confinement snap. Left unpatched,
            # same reasoning as deb.nix's own dontFixup'd dependency
            # derivation: these are already-correct real Ubuntu binaries,
            # built for the exact same base/suite this snap targets. Only
            # usr/ is copied (not the top-level include/lib convenience
            # symlinks nativeDerivationFactory adds for Nix's own
            # cc-wrapper) -- bundles a dependency's -dev headers/
            # pkgconfig/static-lib content too, alongside the runtime
            # .so, since both live in the same merged derivation; harmless
            # bloat, not a correctness bug, documented as a known gap.
            ${lib.concatMapStringsSep "\n" (d: ''
              mkdir -p payload/usr
              cp -a --no-preserve=ownership ${d}/usr/. payload/usr/
              chmod -R u+w payload
            '') allDependencyDerivations}

            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            cp -a payload $out
            runHook postInstall
          '';
        };

        manifest = {
          name = snapName;
          version = args.version;
          inherit base confinement grade;
          platforms.${architecture} = { build-on = [ architecture ]; build-for = [ architecture ]; };
          parts.main = {
            plugin = "dump";
            source = "payload";
            source-type = "local";
          };
          apps.${snapName} = {
            command = "bin/${resolvedMainProgram}";
            plugs = snapPlugs;
          };
        }
        // lib.optionalAttrs (meta ? description) {
          summary = meta.description;
          description = meta.description;
        }
        // lib.optionalAttrs (licenseLine != null) { license = licenseLine; };

        manifestFile = pkgs.writeText "snapcraft.yaml" (builtins.toJSON manifest);
      in
      pkgs.runCommand "${args.pname}-snap" { } ''
        mkdir -p $out/snap
        cp ${manifestFile} $out/snap/snapcraft.yaml
        cp -a ${payload} $out/payload
      ''
    else
      throw "nixothea snap target: unknown role ${role}";
}
