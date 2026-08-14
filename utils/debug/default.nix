# Debugging aids for someone *consuming* nixothea to package their own
# app -- as opposed to utils/targetImpl, which is for someone
# *implementing* a new target. Exposed as `nixothea.lib.utils.debug` (see
# flake.nix). Like the rest of `nixothea.lib`, nothing here is bound to
# nixothea's own pinned nixpkgs.
{
  # { targets, lockFile, definition ? ... }: { <targetName> = <devShell>; ... }
  # A `nix develop .#<targetName>`-able shell per target, built against
  # that target's own real `pkgs` with its real resolved dependencies
  # available. See the file itself for the full parameter reference.
  mkDevShells = import ./mk-dev-shells.nix;

  # { targets, lockFile, definition, options ? {} }: <nix run-able derivation>
  # Optional dependency-declaration linter -- three built-in checks
  # (unused/uselessDuplicates/versionMismatch) plus whatever a target's
  # own `lintRules` add (see lib/mk-target.nix). See the file itself for
  # the full parameter reference.
  lintDependencies = import ./lint-dependencies.nix;

  # { lib, tree }: [ "<logicalDependencyName>" ... ]
  # Flat, deduplicated list of every logical dependency name referenced
  # anywhere in a constructed node tree. Used internally by
  # lintDependencies' own `unused` check; also usable directly from a
  # target's own `lintRules`.
  referencedDependencyNames = import ./referenced-dependency-names.nix;

  # { pkgs, findings }: <nix run-able derivation>
  # Turns a list of `{ rule; target ? null; message; }` findings into a
  # runnable report (prints them, exits nonzero if non-empty). Used
  # internally by lintDependencies' own built-in checks; also usable
  # directly from a target's own `lintRules`.
  mkFindingsReport = import ./mk-findings-report.nix;
}
