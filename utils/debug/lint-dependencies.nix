# Optional, runnable dependency-declaration linter -- three built-in
# checks (all cheap, pure Nix-eval-time computations under the hood) plus
# whatever a target's own `lintRules` add (see lib/mk-target.nix; these
# may be genuinely impure and get executed for real at runtime). Same
# `targets`/`lockFile`/`definition` inputs as `buildTarget`, since the
# `unused` check below needs to actually construct each target's real
# node tree the same way `buildTarget` does.
#
# Always returns a `nix run`-able derivation (never throws at eval time,
# even when the built-in checks already found something at eval time) --
# a caller wires this into their own `apps.${system}.lint` the same way
# `resolve`'s own output gets wired into `apps.${system}.resolve`.
# Running it prints one combined report covering every enabled check
# (built-in and custom) and exits nonzero if anything was found, 0
# otherwise.
#
# The three built-in checks, all under `options.builtin.<name>`, each
# with `{ enabled ? true; }` (plus `versionMismatch`'s own `exclude`):
#
#   unused -- per target: a logical dependency has a resolved lock entry
#     for that target but is never referenced by any buildInputs
#     anywhere in that target's actual built package (root or nested).
#
#   uselessDuplicates -- across every target: two logical dependency
#     names (any two, regardless of what they're named) that, at every
#     target where both happen to be declared, always resolve to the
#     exact same real derivation -- the split into two logical names
#     never once mattered anywhere.
#
#   versionMismatch -- per target: two or more logical dependencies that
#     declare the *same* real name for that target, but resolve to
#     *different* derivations there -- contradicts the shared name.
#     `options.builtin.versionMismatch.exclude.<targetName>` is a list of
#     groups (each >= 2 logical names) permitted to diverge at that
#     target specifically (e.g. intentional multiple-versions-for-
#     backwards-compatibility).
#
# A target's own `lintRules` are configured under `options.<targetName>.<ruleName>`,
# same `{ enabled ? true; ...rule-specific config...; }` shape.
{ targets, lockFile, definition, options ? { } }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  mkFindingsReport = import ./mk-findings-report.nix;
  referencedDependencyNames = import ./referenced-dependency-names.nix;

  # Pure nixpkgs `lib` is identical regardless of which target's pkgs it
  # comes from (same reasoning as lib/resolver.nix's own bootstrapping) --
  # used only for cross-target structural operations (mapAttrsToList,
  # concatLists, sorting, ...), never anything target-specific.
  targetList = builtins.attrValues targets;
  bootstrapLib = (builtins.head targetList).pkgs.lib;

  # This aggregator script (and the built-in findings' own report script)
  # has to actually run on the build machine via `nix run`, regardless of
  # which targets are present -- same reliably-native-pkgs reasoning as
  # lib/resolver.nix's own `resolvePkgs` (a same-system libc variant like
  # pkgsMusl does NOT get real nixpkgs build/host splicing, so building
  # tooling against it directly can silently pull in rebuilding things
  # like GHC from source instead of reusing the well-cached native build
  # -- a real, previously-hit bug, not just a theoretical concern).
  isReliablyNative = t:
    t.pkgs.stdenv.hostPlatform.system != t.pkgs.stdenv.buildPlatform.system
    || (t.pkgs.stdenv.hostPlatform.libc or null) == "glibc";
  anyPkgs = (bootstrapLib.findFirst isReliablyNative (builtins.head targetList) targetList).pkgs;
  reportPkgs = anyPkgs.buildPackages;

  builtinOptions = options.builtin or { };
  isEnabled = opt: opt.enabled or true;

  # Per target: pkgs, lockSection, and the constructed root node --
  # deliberately mirrors lib/build.nix's own customPkgs construction
  # (duplicated rather than shared, since this only ever needs the
  # constructed *node* itself, never buildTarget's finalized result of
  # calling it with `role = "root"`). builtins.mapAttrs, not
  # lib.mapAttrs -- same reasoning as lib/build.nix: no single shared
  # `lib` before each target's own `pkgs` is in scope.
  perTarget = builtins.mapAttrs
    (targetName: target:
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
      in
      { inherit target pkgs lib lockSection tree; })
    targets;

  # Real derivation for one logical dependency at one target, or null if
  # it has no real derivation to offer (metadata-only, same has-a-real-
  # outPath check as wrap-mk-derivation.nix's `unwrap` and
  # mk-dev-shells.nix's own buildInputs filtering).
  realDrvFor = targetName: depName:
    let
      t = perTarget.${targetName};
      v = t.target.nativeDerivationFactory { inherit (t) pkgs; name = depName; entry = t.lockSection.${depName}; };
    in
    if v ? outPath then v else null;

  sameDrv = a: b:
    a != null && b != null
    && builtins.unsafeDiscardStringContext a.drvPath == builtins.unsafeDiscardStringContext b.drvPath;

  ### unused ################################################################

  unusedFindings =
    if !(isEnabled (builtinOptions.unused or { })) then [ ]
    else
      bootstrapLib.concatLists (bootstrapLib.mapAttrsToList
        (targetName: t:
          let
            referenced = referencedDependencyNames { inherit (t) lib tree; };
            declared = builtins.attrNames t.lockSection;
            unreferenced = builtins.filter (n: !(builtins.elem n referenced)) declared;
          in
          map
            (depName: {
              rule = "builtin.unused";
              target = targetName;
              message = ''logical dependency "${depName}" has a resolved entry but is never referenced by any buildInputs in this target's built package -- remove the dependency, or reference it in the shared definition function.'';
            })
            unreferenced)
        perTarget);

  ### uselessDuplicates ######################################################

  allLogicalNames = bootstrapLib.unique
    (bootstrapLib.concatMap (t: builtins.attrNames t.lockSection) (builtins.attrValues perTarget));

  allPairs = xs:
    let n = builtins.length xs;
    in
    bootstrapLib.concatMap
      (i: map (j: [ (builtins.elemAt xs i) (builtins.elemAt xs j) ]) (bootstrapLib.range (i + 1) (n - 1)))
      (bootstrapLib.range 0 (n - 1));

  uselessDuplicateFindings =
    if !(isEnabled (builtinOptions.uselessDuplicates or { })) then [ ]
    else
      bootstrapLib.concatMap
        (pair:
          let
            a = builtins.elemAt pair 0;
            b = builtins.elemAt pair 1;
            sharedTargets = builtins.attrNames
              (bootstrapLib.filterAttrs (_: t: t.lockSection ? ${a} && t.lockSection ? ${b}) perTarget);
          in
          if sharedTargets != [ ]
          && bootstrapLib.all (tn: sameDrv (realDrvFor tn a) (realDrvFor tn b)) sharedTargets
          then
            [{
              rule = "builtin.uselessDuplicates";
              target = null;
              message = ''logical dependencies "${a}" and "${b}" always resolve to the exact same real derivation at every target where both are declared (${bootstrapLib.concatStringsSep ", " sharedTargets}) -- consider merging them into one logical dependency.'';
            }]
          else
            [ ])
        (allPairs allLogicalNames);

  ### versionMismatch ########################################################

  normalizeGroup = g: bootstrapLib.sort (a: b: a < b) g;

  versionMismatchFindings =
    if !(isEnabled (builtinOptions.versionMismatch or { })) then [ ]
    else
      bootstrapLib.concatMap
        (targetName:
          let
            t = perTarget.${targetName};
            byRealName = bootstrapLib.groupBy (depName: t.lockSection.${depName}.name) (builtins.attrNames t.lockSection);
            excludeGroups = map normalizeGroup
              (((builtinOptions.versionMismatch or { }).exclude or { }).${targetName} or [ ]);
          in
          bootstrapLib.concatLists (bootstrapLib.mapAttrsToList
            (realName: group:
              if builtins.length group < 2 || bootstrapLib.elem (normalizeGroup group) excludeGroups then
                [ ]
              else
                let
                  drvs = map (n: realDrvFor targetName n) group;
                  allResolved = !(builtins.any (d: d == null) drvs);
                  allSame = allResolved && bootstrapLib.all (d: sameDrv d (builtins.head drvs)) drvs;
                in
                if !allResolved || allSame then
                  [ ]
                else
                  [{
                    rule = "builtin.versionMismatch";
                    target = targetName;
                    message = ''logical dependencies ${bootstrapLib.concatMapStringsSep ", " (n: "\"${n}\"") group} all declare the real name "${realName}" but resolve to different derivations -- either they should be one logical dependency, or (if intentional) add ${builtins.toJSON group} to options.builtin.versionMismatch.exclude."${targetName}".'';
                  }])
            byRealName))
        (builtins.attrNames perTarget);

  builtinFindings = unusedFindings ++ uselessDuplicateFindings ++ versionMismatchFindings;
  builtinReport = mkFindingsReport { pkgs = reportPkgs; findings = builtinFindings; };

  ### target-defined custom rules, run for real at runtime ##################

  customRuleRuns = bootstrapLib.concatLists (bootstrapLib.mapAttrsToList
    (targetName: t:
      bootstrapLib.filter (x: x != null)
        (bootstrapLib.mapAttrsToList
          (ruleName: ruleFn:
            let ruleOptions = (options.${targetName} or { }).${ruleName} or { };
            in
            if !(isEnabled ruleOptions) then
              null
            else
              {
                label = "${targetName}.${ruleName}";
                drv = ruleFn { inherit (t) pkgs lockSection tree; options = ruleOptions; };
              })
          (t.target.lintRules or { })))
    perTarget);
in
reportPkgs.writeShellApplication {
  name = "nixothea-lint";
  text = ''
    failed=0

    if ! ${bootstrapLib.getExe builtinReport}; then
      failed=1
    fi

    ${bootstrapLib.concatMapStringsSep "\n" (r: ''
      echo "--- ${bootstrapLib.escapeShellArg r.label} ---" >&2
      if ! ${bootstrapLib.getExe r.drv}; then
        failed=1
      fi
    '') customRuleRuns}

    if [ "$failed" -eq 1 ]; then
      echo "nixothea-lint: issues found (see above)" >&2
      exit 1
    fi
    echo "nixothea-lint: no issues found"
  '';
}
