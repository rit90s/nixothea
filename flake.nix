{
  description = "Build deb/rpm/nix/aur/AppImage/Windows installer packages from a Nix derivation closure via pluggable targets";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      # All of these take `pkgs`/`lib` explicitly from the caller rather
      # than binding nixothea's own nixpkgs input, so consumers evaluate
      # against their own nixpkgs pin.
      lib = {
        mkTarget = import ./lib/mk-target.nix;
        mkResolver = import ./lib/resolver.nix;
        buildTarget = import ./lib/build.nix;
        collectDeps = import ./lib/collect-deps.nix;
      };

      # Pre-implemented targets for popular formats, ready to instantiate,
      # e.g. `nixothea.targets.${system}.appimage { icon = ./icon.png; }`.
      # Unlike `lib`, these are bound to nixothea's own pinned nixpkgs,
      # since they need a concrete `pkgs` to build their own tooling.
      targets = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          appimage = import ./targets/appimage.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
          };
          nix = import ./targets/nix.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
          };
          aur = import ./targets/aur.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
            collectDeps = self.lib.collectDeps;
          };
          deb = import ./targets/deb.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
            collectDeps = self.lib.collectDeps;
          };
          dnfFedora = import ./targets/dnf-fedora.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
            collectDeps = self.lib.collectDeps;
          };
          dnfRhel = import ./targets/dnf-rhel.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
            collectDeps = self.lib.collectDeps;
          };
          dnfOpensuse = import ./targets/dnf-opensuse.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
            collectDeps = self.lib.collectDeps;
          };
          # windowsExe/windowsMsi are constructed with the same native
          # `pkgs` as every other target above (their own construction-time
          # `pkgs` is only ever used for the platform-agnostic `.lib`), but
          # actually *using* them needs a `buildTarget`/`mkResolver` call
          # with `pkgs = nixpkgs.legacyPackages.${system}.pkgsCross.mingwW64`
          # (or another Windows cross pkgs) passed in explicitly -- these
          # targets need a real cross-compiled Windows binary, not a
          # repackaged Linux one, so they can't share a single buildTarget
          # call with deb/dnfFedora/etc. the way those share with each
          # other. See targets/windows-exe.nix's header comment.
          windowsExe = import ./targets/windows-exe.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
            collectDeps = self.lib.collectDeps;
          };
          windowsMsi = import ./targets/windows-msi.nix {
            inherit pkgs;
            mkTarget = self.lib.mkTarget;
            collectDeps = self.lib.collectDeps;
          };
        }
      );
    };
}
