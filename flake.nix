{
  description = "Build deb/rpm/nix/aur/AppImage/Windows installer packages from a Nix derivation closure via pluggable targets";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    # All three take `pkgs`/`lib` explicitly from the caller rather than
    # binding nixothea's own nixpkgs input, so consumers evaluate against
    # their own nixpkgs pin.
    lib = {
      mkTarget = import ./lib/mk-target.nix;
      mkResolver = import ./lib/resolver.nix;
      buildTarget = import ./lib/build.nix;
    };
  };
}
