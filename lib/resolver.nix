# Phase 1: dependency resolution.
#
# `dependencies` is the user's full dependency spec:
#
#   { <logicalName> = { <targetName> = { name = "..."; versionRange = "..."; ... }; ...}; ... }
#
# `targets` is the same explicit, caller-controlled attrset used across both
# phases: { <targetName> = <target module, see ./mk-target.nix>; }. Instantiating
# the same target implementation under two different names (e.g. `debian`
# and `ubuntu`, each a separately-configured `deb` target) resolves and
# builds them independently. Each target carries its own `pkgs` (fixed
# when it was constructed -- see mk-target.nix), so `targets` here can
# freely mix targets that need fundamentally different pkgs (e.g. `deb`
# alongside `windowsExe`) in one call. Returns a `nix run`-able derivation:
# running it invokes each requested target's `resolve`, merging the
# results into one combined lock file (default ./nixothea.lock.json,
# override with --out), each under its own `.targets.<name>` section. With
# no arguments it resolves every target in `targets`; pass one or more
# `--target <name>` to resolve only those (existing sections for other
# targets are left untouched).
{ dependencies, targets }:
let
  candidates = builtins.attrValues targets;

  # `lib` itself is identical regardless of which target's pkgs it comes
  # from (nixpkgs' own pure function library doesn't vary with
  # cross-compilation or libc choice), so it's safe to bootstrap this
  # from whichever target happens to be first.
  lib = (builtins.head candidates).pkgs.lib;

  # For the small dispatcher script below (see the `buildPackages`
  # comment further down), we need *a* target's pkgs whose own
  # `.buildPackages` is guaranteed to resolve to the real, well-cached
  # native build-machine pkgs -- not just any target's. That holds for a
  # genuine cross pkgs (hostPlatform != buildPlatform, where nixpkgs'
  # real build/host splicing kicks in -- verified empirically for
  # pkgsCross.mingwW64) and for a plain native pkgs, but NOT for a
  # same-system libc variant like pkgsMusl: its hostPlatform.system
  # equals buildPlatform.system, so nixpkgs never splices it at all --
  # `pkgsMusl.buildPackages` silently aliases back to pkgsMusl itself
  # (verified empirically: `pkgsMusl.buildPackages.jq` is the *musl* jq,
  # a different, far-less-cached store path than the native one, whose
  # own build pulled in compiling GHC from source). Prefers a reliably
  # native candidate when one exists; falls back to whatever's first
  # otherwise (e.g. every target in this call happens to need some other
  # libc variant) -- imperfect, but no worse than before this existed.
  isReliablyNative = t:
    t.pkgs.stdenv.hostPlatform.system != t.pkgs.stdenv.buildPlatform.system
    || (t.pkgs.stdenv.hostPlatform.libc or null) == "glibc";
  anyPkgs = (lib.findFirst isReliablyNative (builtins.head candidates) candidates).pkgs;

  # `resolve` is always a build-machine-side network/CLI-tool invocation
  # (apt, dnf5, apk fetch, ...) -- it never needs to be built *for* the
  # target platform the way the real compile does, regardless of which
  # target it belongs to: e.g. `deb`'s `resolve` needs a real `apt`
  # binary that runs on the build machine and is merely *told* which
  # architecture to resolve against (`APT::Architecture=...`), not an
  # architecture-specific `apt` binary itself. So every target's
  # `resolve` gets built with the same reliably-native pkgs as the
  # dispatcher below, never `target.pkgs` directly -- which matters in
  # practice, not just in theory: `pkgs.writeShellApplication` (used by
  # several targets' resolvers, including apk's) runs shellcheck on the
  # generated script as part of its own build, and a musl `shellcheck`
  # (a real Haskell binary) turned out to be so poorly cached that
  # building it pulled in compiling GHC from source.
  resolvePkgs = anyPkgs.buildPackages;

  # This target's slice of `dependencies`: only the logical deps that
  # declared an entry for its name, with just that entry (not the whole
  # per-target attrset).
  sliceFor = name:
    lib.filterAttrs (_: v: v != null)
      (lib.mapAttrs (_: entry: entry.${name} or null) dependencies);

  resolvers = lib.mapAttrs
    (name: target: lib.getExe (target.resolve {
      pkgs = resolvePkgs;
      deps = sliceFor name;
    }))
    targets;

  dispatch = lib.concatStringsSep "\n"
    (lib.mapAttrsToList
      (name: exe: "resolvers[${lib.escapeShellArg name}]=${lib.escapeShellArg exe}")
      resolvers);

  allNames = lib.concatMapStringsSep " " lib.escapeShellArg (builtins.attrNames targets);
in
# Same `resolvePkgs` as every per-target resolve call above -- this
# dispatcher also has to actually run on the build machine via `nix run`,
# so it needs the same reliably-native tooling, for the same reason.
resolvePkgs.writeShellApplication {
  name = "nixothea-resolve";
  runtimeInputs = [ resolvePkgs.jq ];
  text = ''
    declare -A resolvers
    ${dispatch}

    out="nixothea.lock.json"
    wanted=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out="$2"; shift 2 ;;
        --target) wanted+=("$2"); shift 2 ;;
        *) echo "nixothea-resolve: unknown argument: $1" >&2; exit 1 ;;
      esac
    done
    if [ ''${#wanted[@]} -eq 0 ]; then
      wanted=(${allNames})
    fi

    if [ -f "$out" ]; then
      lock=$(cat "$out")
    else
      lock='{"targets":{}}'
    fi

    for name in "''${wanted[@]}"; do
      resolver="''${resolvers[$name]:-}"
      if [ -z "$resolver" ]; then
        echo "nixothea-resolve: unknown target: $name" >&2
        exit 1
      fi
      section=$("$resolver")
      lock=$(jq --argjson section "$section" --arg name "$name" \
        '.targets[$name] = $section' <<< "$lock")
    done

    jq . <<< "$lock" > "$out"
    echo "nixothea-resolve: wrote $out" >&2
  '';
}
