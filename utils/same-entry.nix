# Collapses the common "same real name (and optionally version) on every
# target" pattern out of a `dependencies` block -- see doc/user-manual.md's
# step 3 for the shape this produces. Exposed as `nixothea.lib.utils.sameEntry`
# (see flake.nix); like the rest of `nixothea.lib`, `lib` is a call-time
# argument, not bound at import time.
#
#   { lib, targets, default, overrides ? {} }: <dependencies attrset>
#
# targets:   the same target attrset callers already build for
#            mkResolver/buildTarget (attrNames used), or a plain list of
#            target names directly -- either works, since only the names
#            are needed here.
# default:   { <logicalName> = <value>; ... } -- the value used for every
#            target unless that (target, logicalName) pair has an entry
#            in `overrides`.
# overrides: { <targetName> = { <logicalName> = <value>; ... }; ... } --
#            replaces the default value for that one (target, logicalName)
#            pair. Always replaces the whole entry, never merged
#            field-by-field with the default.
#
# Each <value> (in `default` or `overrides`) may be a bare string
# (shorthand for `{ name = <value>; }`) or a full entry attrset (e.g.
# `{ name = "..."; version = "..."; }`) when more than the name needs
# pinning.
#
# Every logical dependency always gets an entry for every target in
# `targets` -- there's no way to opt a target out here (matches
# `dependencies`' own shape: a target simply not having a given logical
# dependency is expressed by that target being absent from `targets`
# altogether, not by a per-entry omission).
#
# `overrides` naming a target or logical name that doesn't actually exist
# (a typo) is a hard error rather than being silently ignored, collecting
# every such mistake into one message instead of stopping at the first.
{ lib, targets, default, overrides ? { } }:
let
  targetNames = if builtins.isList targets then targets else builtins.attrNames targets;
  logicalNames = builtins.attrNames default;

  unknownOverrideTargets = lib.subtractLists targetNames (builtins.attrNames overrides);

  unknownOverrideLogicalNames = lib.concatMap
    (t: map (n: "${t}.${n}")
      (lib.subtractLists logicalNames (builtins.attrNames overrides.${t})))
    (builtins.attrNames overrides);

  errors =
    (map (t: "overrides.${t}: not a target in `targets`") unknownOverrideTargets)
    ++ (map (p: "overrides.${p}: not a logical name in `default`") unknownOverrideLogicalNames);

  normalize = v: if builtins.isString v then { name = v; } else v;
in
if errors != [ ]
then throw ''
  nixothea sameEntry: ${toString (builtins.length errors)} invalid override(s):
  ${lib.concatMapStringsSep "\n" (e: "  - ${e}") errors}''
else lib.mapAttrs
  (logicalName: defaultValue:
    lib.genAttrs targetNames
      (t: normalize (overrides.${t}.${logicalName} or defaultValue)))
  default
