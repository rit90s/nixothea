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
# builds them independently. Returns a `nix run`-able derivation: running it
# invokes each requested target's `resolve`, merging the results into one
# combined lock file (default ./nixothea.lock.json, override with --out),
# each under its own `.targets.<name>` section. With no arguments it
# resolves every target in `targets`; pass one or more `--target <name>` to
# resolve only those (existing sections for other targets are left
# untouched).
{ pkgs, dependencies, targets }:
let
  lib = pkgs.lib;

  # This target's slice of `dependencies`: only the logical deps that
  # declared an entry for its name, with just that entry (not the whole
  # per-target attrset).
  sliceFor = name:
    lib.filterAttrs (_: v: v != null)
      (lib.mapAttrs (_: entry: entry.${name} or null) dependencies);

  resolvers = lib.mapAttrs
    (name: target: lib.getExe (target.resolve {
      inherit pkgs;
      deps = sliceFor name;
    }))
    targets;

  dispatch = lib.concatStringsSep "\n"
    (lib.mapAttrsToList
      (name: exe: "resolvers[${lib.escapeShellArg name}]=${lib.escapeShellArg exe}")
      resolvers);

  allNames = lib.concatMapStringsSep " " lib.escapeShellArg (builtins.attrNames targets);
in
pkgs.writeShellApplication {
  name = "nixothea-resolve";
  runtimeInputs = [ pkgs.jq ];
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
