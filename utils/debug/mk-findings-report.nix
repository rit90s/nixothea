# Turns a list of findings into a `nix run`-able derivation: prints them
# formatted and exits nonzero if the list is non-empty, prints a clean
# "no issues found" and exits 0 if it's empty. Used internally by
# lintDependencies for its three built-in checks; also directly usable by
# a target's own `lintRules` entries (see lib/mk-target.nix) that have
# nothing impure to do -- an impure rule is free to ignore this entirely
# and build its own runnable derivation by hand instead, or call this too
# if it also has some eval-time-computed findings to report alongside
# whatever real work it does at runtime.
#
# One finding is `{ rule; target ? null; message; }` -- `rule` identifies
# which check produced it (e.g. "builtin.unused", or "<targetName>.<ruleName>"
# for a target-defined one), `target` is the target instance it's about
# (omitted for a cross-target finding like a useless-duplicate pair),
# `message` is the human-readable explanation.
{ pkgs, findings }:
let
  lib = pkgs.lib;
  formatFinding = f:
    "[FAIL] ${f.rule}${lib.optionalString ((f.target or null) != null) " target \"${f.target}\""}: ${f.message}";
in
pkgs.writeShellApplication {
  name = "nixothea-lint-report";
  text = ''
    ${lib.concatMapStringsSep "\n" (f: "echo ${lib.escapeShellArg (formatFinding f)} >&2") findings}
    ${if findings == [ ] then
      ''echo "nixothea-lint-report: no issues found"''
    else
      ''
        echo "nixothea-lint-report: ${toString (builtins.length findings)} issue(s) found" >&2
        exit 1
      ''
    }
  '';
}
