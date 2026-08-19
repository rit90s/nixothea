# Minimal test harness shared by unit/ and e2e/ -- not part of nixothea's
# own public API, purely internal to this test folder. Deliberately tiny
# rather than pulling in nixpkgs' own lib.debug.runTests: it has no way to
# express a "must throw" case (which several core asserts need), and
# reusing utils/debug/mk-findings-report.nix's report format below keeps
# this test suite dogfooding the same tooling the rest of the project
# exposes to consumers.
{ lib }:
let
  mkFindingsReport = import ../utils/debug/mk-findings-report.nix;
in
rec {
  # One case is either:
  #   { name; expr; expected; }   -- expr must evaluate (deeply) without
  #                                   throwing, and equal `expected`.
  #   { name; expr; throws = true; } -- forcing expr must throw. Nix has
  #     no way to inspect a thrown message from pure Nix code
  #     (`builtins.tryEval` only reports success/failure), so this can
  #     only assert *that* it throws, never the message text -- message
  #     wording is instead verified by hand against real `nix eval`
  #     output while writing each test (see e.g. test/unit/same-entry.nix).
  #
  # Returns `null` on success, or a human-readable failure string.
  runCase = c:
    let
      forced = builtins.tryEval (builtins.deepSeq c.expr c.expr);
      wantsThrow = (c.throws or false) == true;
    in
    if !(c ? expected) && !wantsThrow then
      throw ''test case "${c.name}": must set either `expected` or `throws = true`''
    else if wantsThrow then
      (if forced.success
       then ''"${c.name}": expected a throw, but evaluated successfully''
       else null)
    else if !forced.success then
      ''"${c.name}": threw unexpectedly (expected ${builtins.toJSON c.expected})''
    else if forced.value != c.expected then
      ''"${c.name}": expected ${builtins.toJSON c.expected}, got ${builtins.toJSON forced.value}''
    else
      null;

  # [ case ] -> [ "failure description" ], only the failures.
  runCases = cases: lib.filter (f: f != null) (map runCase cases);

  # Turns a named module's cases into a `checks.${system}`-able
  # derivation: throws immediately (at the point Nix has to evaluate this
  # derivation's own arguments -- before anything is actually built, and
  # well before any sandboxed build step runs) if any case failed,
  # listing every failure, not just the first; otherwise builds a trivial
  # marker file for real, so `nix flake check`/`nix build` has an actual
  # derivation to report success on.
  mkCheck = { pkgs, name, cases }:
    let
      failures = runCases cases;
      total = builtins.length cases;
    in
    pkgs.runCommand "nixothea-test-unit-${name}" { } (
      if failures == [ ] then
        ''echo "${name}: ${toString total} test(s) passed" > $out''
      else
        throw ''
          nixothea unit tests (${name}): ${toString (builtins.length failures)}/${toString total} failed:
          ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failures}''
    );

  # Same cases, as a `nix run`-able report instead of an eval-time throw --
  # for local iteration, where seeing every module's results printed
  # together (rather than stopping at the first module `nix flake check`
  # happens to evaluate) is more useful.
  mkReport = { pkgs, name, cases }:
    mkFindingsReport {
      inherit pkgs;
      findings = map (msg: { rule = name; message = msg; }) (runCases cases);
    };
}
