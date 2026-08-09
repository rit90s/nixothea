# A constructor: `nixothea.targets.homebrew { }` returns a target that
# produces a Homebrew Formula (a Ruby recipe file) -- like the aur target,
# nixothea never compiles the real software for this target, only
# generates the recipe. The real compile happens later, for real, when
# `brew install` runs the Formula's `install do` block on the user's own
# machine (Homebrew supports both macOS and Linux -- "Homebrew on Linux").
# This sidesteps the practical problem a self-built binary target would
# have here: genuine Linux->Darwin cross-compilation isn't a well-
# supported path in nixpkgs the way mingw is for Windows, and this way
# nixothea never needs a real Darwin builder at all -- the user's own
# `brew install` does the real compiling on their own machine, exactly
# like virtually every real-world Formula already works.
#
# Unlike aur.nix, a Formula's `url`/`sha256` genuinely can't be omitted --
# Homebrew's Formula class structurally requires a fetchable source
# (unlike a PKGBUILD, which is happy to run build()/package() against
# nothing) -- so homebrewSource/homebrewSourceSha256 (set alongside
# pname/version/meta/buildPhase/installPhase on the pkgs.mkDerivation
# call, same convention as aur.nix's aurSource/aurSourceSha256) are
# mandatory here, not optional-but-paired.
#
# Known limitations, kept out of scope for this pass:
#   - no build-only/runtime dependency distinction -- every declared
#     dependency becomes a plain runtime `depends_on`;
#   - a dependency's versionConstraint (see mk-target.nix) has no
#     representable equivalent in a plain `depends_on "name"` and is
#     silently ignored;
#   - no auto-generated `test do` block (brew audit wants one for real
#     tap submissions, but it's not required for `brew install` to work);
#   - class-name sanitization doesn't replicate Homebrew's own leading
#     -digit naming convention (e.g. real "7-zip" -> "SevenZip") -- a
#     pname starting with a digit gets an arbitrary "X" prefix instead,
#     which would need manual renaming for real-world submission;
#   - the embedded shell text is spliced into a Ruby squiggly heredoc
#     (<<~) -- a buildPhase/installPhase that happens to contain the
#     literal two characters "#{" (Ruby interpolation syntax) would be
#     misinterpreted; not sanitized against here, same class of trust-the-
#     caller-supplied-text tradeoff as every other target's templating.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  licenseName = l: if builtins.isString l then l else (l.spdxId or l.shortName or null);
  licenseNames = l:
    if l == null then [ ]
    else if builtins.isList l then lib.filter (x: x != null) (map licenseName l)
    else lib.filter (x: x != null) [ (licenseName l) ];

  # Ruby class names must start with an uppercase letter -- "my-tool" (or
  # "my_tool"/"my.tool") becomes "MyTool". See the header comment for the
  # leading-digit caveat.
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
  # Independently incremented when only the packaging (not the underlying
  # software) changes -- Homebrew's own name for exactly the concept
  # aur.nix's pkgrel covers.
  revision ? null,
}:
mkTarget {
  inherit lib;

  # No live registry to resolve against -- see aur.nix's resolve for the
  # same reasoning (pacman/brew both resolve dependencies themselves,
  # later, at install time).
  resolve = { pkgs, deps }:
    pkgs.writeShellApplication {
      name = "resolve-homebrew";
      text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
    };

  # Pure metadata -- no real derivation, mirrors aur.nix's
  # nativeDerivationFactory exactly. entry.name is the real Homebrew
  # formula name; entry.versionConstraint (if set) is silently ignored --
  # see the header comment.
  nativeDerivationFactory = { pkgs, name, entry }:
    {
      formulaName = entry.name;
      versionConstraint = entry.versionConstraint or null;
    };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      # Never actually realized -- same reasoning as aur.nix.
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
