# Aggregates the e2e suite: real builds/executions against real,
# pre-implemented targets (never fakes -- see test/unit/ for that). Each
# check's own build script performs its assertions and fails the build on
# mismatch, so `nix flake check`/`nix build .#checks.<system>.e2e-<name>`
# already runs everything meaningful; `report` (wired to
# `apps.${system}.test-e2e` in flake.nix) is a thin convenience wrapper
# that just builds every e2e check in one `nix build` call with streamed
# logs, for local iteration.
{ pkgs, nixothea, system }:
let
  lib = pkgs.lib;
  targets = nixothea.targets.${system};

  nixTarget = targets.nix { };
  aurTarget = targets.aur { };
  tarballTarget = targets.tarball { };

  checks = {
    pipeline = import ./pipeline.nix { inherit pkgs nixTarget aurTarget; };
    lint = import ./lint.nix { inherit pkgs nixTarget; };
    tree = import ./tree.nix { inherit pkgs nixTarget; };
    dev-shells = import ./dev-shells.nix { inherit pkgs nixTarget; };
    main-program = import ./main-program.nix { inherit pkgs tarballTarget; };
  };

  attrs = lib.concatMapStringsSep " " (name: ".#checks.${system}.e2e-${name}") (builtins.attrNames checks);

  report = pkgs.writeShellApplication {
    name = "nixothea-test-e2e";
    text = ''
      echo "nixothea-test-e2e: building ${attrs}"
      nix build ${attrs} -L --no-link
      echo "nixothea-test-e2e: all e2e checks passed"
    '';
  };
in
{ inherit checks report; }
