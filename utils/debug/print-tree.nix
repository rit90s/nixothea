# Renders one target's real constructed dependency tree -- either as an
# indented text tree (default, stdout) or a self-contained, interactive
# HTML graph (`--html <path>`). A single `nix run`-able executable,
# mirroring `mkResolver`'s own dispatch style (a `case "$target" in ...`
# picking between per-target, pre-rendered content computed once at Nix
# -eval time).
#
# Unlike `collectDeps` (see collect-deps.nix), which deliberately
# flattens everything into two deduplicated lists, this walks
# `.nodeDeps`/`.dependencyDeps` itself to preserve real nesting/depth --
# that's exactly the information collectDeps throws away and this needs
# to render a tree at all.
#
# `--target <name>` is mandatory: a tree is inherently one target's own
# constructed package (built via `definition` against that target's real
# `pkgs`), so there's no meaningful "every target at once" default the
# way `mkResolver`'s resolve has.
{ targets, lockFile, definition }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);
  targetList = builtins.attrValues targets;
  bootstrapLib = (builtins.head targetList).pkgs.lib;

  # This dispatcher (and every per-target writeText file it embeds) has
  # to actually run/build on the build machine regardless of which
  # targets are present -- same reliably-native-pkgs reasoning as
  # lib/resolver.nix's own `resolvePkgs` (see its comment for the real,
  # previously-hit bug this avoids: a same-system libc variant like
  # pkgsMusl doesn't get real nixpkgs build/host splicing).
  isReliablyNative = t:
    t.pkgs.stdenv.hostPlatform.system != t.pkgs.stdenv.buildPlatform.system
    || (t.pkgs.stdenv.hostPlatform.libc or null) == "glibc";
  anyPkgs = (bootstrapLib.findFirst isReliablyNative (builtins.head targetList) targetList).pkgs;
  scriptPkgs = anyPkgs.buildPackages;

  mkHtml = import ./print-tree-html.nix;

  # Per target: construct the real tree (same customPkgs construction as
  # lib/build.nix/lint-dependencies.nix -- duplicated rather than shared,
  # since this only ever needs the constructed *node*, never buildTarget's
  # finalized result of calling it with `role = "root"`), then walk it.
  renderTarget = targetName: target:
    let
      pkgs = target.pkgs;
      lib = pkgs.lib;
      lockSection = lock.targets.${targetName} or { };

      customDeps = lib.mapAttrs
        (depName: entry:
          (target.nativeDerivationFactory { inherit pkgs; name = depName; inherit entry; })
          // { _nixotheaDependency = true; _nixotheaDependencyName = depName; })
        lockSection;

      customPkgs = customDeps // {
        mkDerivation = import ../../lib/wrap-mk-derivation.nix { inherit pkgs target; };
      };

      tree = definition { pkgs = customPkgs; };

      # Stable, string-context-free identity for a node/dependency --
      # same drvPath-based identity `collectDeps`/`wrap-mk-derivation.nix`
      # already use for nodes, and the same `_nixotheaDependencyName`
      # -based identity they use for dependencies (hashed only so it's a
      # short, safe-for-HTML-id/JS-key string).
      nodeId = node: "node_" + builtins.hashString "sha256" (builtins.unsafeDiscardStringContext node.realDrv.drvPath);
      depId = dep: "dep_" + builtins.hashString "sha256" dep._nixotheaDependencyName;

      # Best-effort resolved version for a dependency -- most targets put
      # it directly on the lock entry (`entry.version`, if the caller set
      # one), but a few (deb/apk) nest the real resolved version inside a
      # `packages[]` list instead (see e.g. targets/deb/resolver.nix).
      # `null` (shown as nothing) if neither shape has one.
      depVersion = entry:
        entry.version or
          (let ps = entry.packages or null;
           in if ps != null && ps != [ ] then (builtins.head ps).version or null else null);

      indent = n: lib.concatStrings (lib.genList (_: "  ") n);

      # Threads one accumulator ({ visited; edges; textLines; }) through
      # the whole recursive walk -- Nix has no mutable state, so this is
      # a fold, not a loop. `visited` doubles as both diamond detection
      # (for the text tree's "(see above)") and the deduplicated node/
      # dependency set the HTML graph needs (one box per unique id, no
      # matter how many times it's reached).
      walkNode = { node, depth, parentId, acc }:
        let
          id = nodeId node;
          seen = acc.visited ? ${id};
          version = node.realDrv.version or "?";
          accEdged = if parentId == null then acc else acc // { edges = acc.edges ++ [{ from = parentId; to = id; }]; };
        in
        if seen then
          accEdged // { textLines = accEdged.textLines ++ [ "${indent depth}${node.realDrv.pname} ${version} (see above)" ]; }
        else
          let
            acc1 = accEdged // {
              visited = accEdged.visited // {
                ${id} = { kind = "node"; label = node.realDrv.pname; version = version; realName = ""; };
              };
              textLines = accEdged.textLines ++ [ "${indent depth}${node.realDrv.pname} ${version}" ];
            };
            acc2 = lib.foldl'
              (a: dep: walkDep { inherit dep; depth = depth + 1; parentId = id; acc = a; })
              acc1
              node.dependencyDeps;
            acc3 = lib.foldl'
              (a: child: walkNode { node = child; depth = depth + 1; parentId = id; acc = a; })
              acc2
              node.nodeDeps;
          in
          acc3;

      walkDep = { dep, depth, parentId, acc }:
        let
          logicalName = dep._nixotheaDependencyName;
          id = depId dep;
          entry = lockSection.${logicalName} or { };
          realName = entry.name or "?";
          version = depVersion entry;
          versionSuffix = if version == null then "" else " ${version}";
          seen = acc.visited ? ${id};
          accEdged = acc // { edges = acc.edges ++ [{ from = parentId; to = id; }]; };
        in
        if seen then
          accEdged // { textLines = accEdged.textLines ++ [ "${indent depth}${logicalName} \"${realName}\"${versionSuffix} (see above)" ]; }
        else
          accEdged // {
            visited = accEdged.visited // {
              ${id} = { kind = "dependency"; label = logicalName; realName = realName; version = if version == null then "" else version; };
            };
            textLines = accEdged.textLines ++ [ "${indent depth}${logicalName} \"${realName}\"${versionSuffix}" ];
          };

      walked = walkNode {
        node = tree;
        depth = 0;
        parentId = null;
        acc = { visited = { }; edges = [ ]; textLines = [ ]; };
      };

      textTree = lib.concatStringsSep "\n" walked.textLines + "\n";

      graphData = {
        rootId = nodeId tree;
        nodes = lib.mapAttrsToList (id: n: n // { inherit id; }) walked.visited;
        edges = walked.edges;
      };

      html = mkHtml { inherit targetName graphData; };
    in
    {
      textFile = scriptPkgs.writeText "tree-${targetName}.txt" textTree;
      htmlFile = scriptPkgs.writeText "tree-${targetName}.html" html;
    };

  rendered = builtins.mapAttrs renderTarget targets;

  dispatchCases = bootstrapLib.concatStringsSep "\n" (map
    (targetName: ''
      ${bootstrapLib.escapeShellArg targetName})
        TEXT_FILE=${rendered.${targetName}.textFile}
        HTML_FILE=${rendered.${targetName}.htmlFile}
        ;;
    '')
    (builtins.attrNames targets));
in
scriptPkgs.writeShellApplication {
  name = "nixothea-print-tree";
  text = ''
    target=""
    html_out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --target) target="$2"; shift 2 ;;
        --html) html_out="$2"; shift 2 ;;
        *) echo "nixothea-print-tree: unknown argument: $1" >&2; exit 1 ;;
      esac
    done
    if [ -z "$target" ]; then
      echo "nixothea-print-tree: --target <name> is required" >&2
      exit 1
    fi

    TEXT_FILE=""
    HTML_FILE=""
    case "$target" in
      ${dispatchCases}
      *) echo "nixothea-print-tree: unknown target: $target" >&2; exit 1 ;;
    esac

    if [ -n "$html_out" ]; then
      cp "$HTML_FILE" "$html_out"
      echo "nixothea-print-tree: wrote $html_out"
    else
      cat "$TEXT_FILE"
    fi
  '';
}
