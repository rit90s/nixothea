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
        }
      );
    };
}
