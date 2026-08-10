# nativeDerivationFactory: pure metadata, no real derivation, mirrors
# aur's exactly. entry.name is the real Homebrew formula name;
# entry.versionConstraint (if set) is silently ignored -- see the
# className/dependsLines usage below.
#
# mkDerivation: "root" builds one combined Formula, same nested-node merge
# as every other target. "dependency" is never actually realized -- same
# reasoning as aur.
{ lib, collectDeps, revision }:
let
  licenseName = l: if builtins.isString l then l else (l.spdxId or l.shortName or null);
  licenseNames = l:
    if l == null then [ ]
    else if builtins.isList l then lib.filter (x: x != null) (map licenseName l)
    else lib.filter (x: x != null) [ (licenseName l) ];

  # Ruby class names must start with an uppercase letter -- "my-tool" (or
  # "my_tool"/"my.tool") becomes "MyTool". A pname starting with a digit
  # gets an arbitrary "X" prefix instead (real Homebrew's own leading-digit
  # convention, e.g. real "7-zip" -> "SevenZip", isn't replicated -- would
  # need manual renaming for real-world submission).
  className = name:
    let
      segments = lib.filter (s: s != "")
        (lib.splitString "-" (lib.replaceStrings [ "_" "." ] [ "-" "-" ] name));
      capitalize = s: lib.toUpper (lib.substring 0 1 s) + lib.substring 1 (-1) s;
      joined = lib.concatStrings (map capitalize segments);
    in
    if builtins.match "[0-9].*" joined != null then "X${joined}" else joined;

  # A Ruby single-quoted string literal from an arbitrary Nix string --
  # single-quoted so only \ and ' need escaping (no other Ruby escape
  # sequences to worry about misinterpreting), unlike nixothea's other
  # targets which escape for shell (this file's values land in Ruby
  # source, not a shell command line).
  rubyString = s: "'" + lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] s + "'";
in
{
  nativeDerivationFactory = { pkgs, name, entry }:
    {
      formulaName = entry.name;
      versionConstraint = entry.versionConstraint or null;
    };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        allDependencies = builtins.attrValues (builtins.listToAttrs
          (map (d: { name = d._nixotheaDependencyName; value = d; })
            (dependencyDeps ++ collected.dependencies)));

        # "One combined package", same as every other target's nested-node
        # merge: every transitively-reachable node's own build/install
        # steps, followed by the root's own, concatenated in collectDeps'
        # order (not a topological merge).
        steps = phase: map (n: n.args.${phase} or "") collected.nodes ++ [ (args.${phase} or "") ];

        meta = args.meta or { };
        licenses = licenseNames (meta.license or null);

        homebrewSource = args.homebrewSource or
          (throw "nixothea homebrew target: ${args.pname} must set homebrewSource -- a real, fetchable URL for its upstream source (Homebrew's Formula class requires one, unlike aur.nix's PKGBUILD, which can run build()/package() against nothing)");
        homebrewSourceSha256 = args.homebrewSourceSha256 or
          (throw "nixothea homebrew target: ${args.pname} must set homebrewSourceSha256 alongside homebrewSource");

        formulaClass = className args.pname;

        licenseLine =
          if licenses == [ ] then
            ""
          else if builtins.length licenses == 1 then
            "  license ${rubyString (builtins.head licenses)}"
          else
            "  license any_of: [${lib.concatMapStringsSep ", " rubyString licenses}]";

        dependsLines = lib.concatMapStringsSep "\n"
          (d: "  depends_on ${rubyString d.formulaName}")
          allDependencies;

        buildStep = lib.concatStringsSep "\n" (steps "buildPhase");
        installStep = lib.concatStringsSep "\n" (steps "installPhase");

        formulaFile = pkgs.writeText "${lib.toLower args.pname}.rb" ''
          class ${formulaClass} < Formula
            ${lib.optionalString (meta ? description) "desc ${rubyString meta.description}"}
            ${lib.optionalString (meta ? homepage) "homepage ${rubyString meta.homepage}"}
            url ${rubyString homebrewSource}
            sha256 ${rubyString homebrewSourceSha256}
            version ${rubyString args.version}
            ${lib.optionalString (revision != null) "revision ${toString revision}"}
          ${licenseLine}
          ${dependsLines}

            def install
              system "bash", "-c", <<~NIXOTHEA_BUILD
          ${buildStep}
              NIXOTHEA_BUILD
              system "bash", "-c", <<~NIXOTHEA_INSTALL
                out=#{prefix.to_s.shellescape}
          ${installStep}
              NIXOTHEA_INSTALL
            end
          end
        '';
      in
      pkgs.runCommand "${args.pname}-homebrew" { } ''
        mkdir -p $out
        cp ${formulaFile} $out/${lib.toLower args.pname}.rb
      ''
    else
      throw "nixothea homebrew target: unknown role ${role}";
}
