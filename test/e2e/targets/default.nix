# Aggregates per-target e2e tests (test/e2e/targets/<name>.nix). Each
# module returns `{ checks = { <name> = <drv>; ... }; apps = { <name> = <drv>; ... } ? {}; }`
# -- `checks` entries are real, sandboxed builds (structural validation,
# and direct execution for formats runnable without extra host tooling:
# nix/appimage/tarball); `apps` entries need real host-level tooling this
# repo's own Nix sandbox can't provide (a container engine, a real target
# -OS userspace) and are exposed as `nix run`-able apps instead -- see
# each module's own header comment for why.
{ pkgs, nixothea, system }:
let
  lib = pkgs.lib;
  targets = nixothea.targets.${system};

  perTarget = {
    nix = import ./nix.nix { inherit pkgs targets; };
    appimage = import ./appimage.nix { inherit pkgs targets; };
    tarball = import ./tarball.nix { inherit pkgs targets; };
    docker = import ./docker.nix { inherit pkgs targets; };
    snap = import ./snap.nix { inherit pkgs targets; };
    deb = import ./deb.nix { inherit pkgs targets; };
    apk = import ./apk.nix { inherit pkgs targets; };
    dnfFedora = import ./dnf-fedora.nix { inherit pkgs targets; };
    dnfRhel = import ./dnf-rhel.nix { inherit pkgs targets; };
    dnfOpensuse = import ./dnf-opensuse.nix { inherit pkgs targets; };
    aur = import ./aur.nix { inherit pkgs targets; };
    homebrew = import ./homebrew.nix { inherit pkgs targets; };
    flatpak = import ./flatpak.nix { inherit pkgs targets; };
    windowsExe = import ./windows-exe.nix { inherit pkgs targets; };
    windowsMsi = import ./windows-msi.nix { inherit pkgs targets; };
  };

  checks = lib.concatMapAttrs
    (targetName: t:
      lib.mapAttrs'
        (n: v: lib.nameValuePair "target-${targetName}-${n}" v)
        (t.checks or { }))
    perTarget;

  apps = lib.concatMapAttrs
    (targetName: t:
      lib.mapAttrs'
        (n: v: lib.nameValuePair "test-target-${targetName}-${n}" {
          type = "app";
          program = lib.getExe v;
        })
        (t.apps or { }))
    perTarget;
in
{ inherit checks apps; }
