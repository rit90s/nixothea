{
  description = "Build deb/rpm/nix/aur/AppImage/Windows installer packages from a Nix derivation closure via pluggable targets";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      lib = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in { }
      );

      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in { }
      );
    };
}
