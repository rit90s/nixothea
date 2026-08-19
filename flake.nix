{
  description = "Build deb/rpm/nix/aur/AppImage/Windows installer packages from a Nix derivation closure via pluggable targets";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      # None of these bind nixothea's own nixpkgs input, so consumers
      # evaluate against their own nixpkgs pin: `mkTarget` takes `pkgs`/
      # `lib` explicitly from the caller (fixing the pkgs that one target
      # itself builds against -- see lib/mk-target.nix); `buildTarget`/
      # `mkResolver` need no `pkgs` of their own at all, since every
      # target in the `targets` attrset they're given already carries its
      # own.
      lib = {
        mkTarget = import ./lib/mk-target.nix;
        mkResolver = import ./lib/resolver.nix;
        buildTarget = import ./lib/build.nix;
        collectDeps = import ./lib/collect-deps.nix;

        # Optional helpers for implementing a target (see
        # doc/implementing-a-target.md) -- not part of the core contract
        # above, just duplication several of nixothea's own
        # pre-implemented targets happened to share.
        utils.targetImpl = import ./utils/targetImpl;

        # Optional helpers for someone *consuming* nixothea -- debugging
        # their own app against one target's real dependencies, not
        # implementing a new target (that's utils.targetImpl above).
        utils.debug = import ./utils/debug;

        # Collapses the common "same real name (and optionally version)
        # on every target" pattern out of a `dependencies` block. See the
        # file itself for the full parameter reference.
        utils.sameEntry = import ./utils/same-entry.nix;
      };

      # Pre-implemented targets for popular formats, ready to instantiate,
      # e.g. `nixothea.targets.${system}.appimage { icon = ./icon.png; }`.
      # Unlike `lib`, these are bound to nixothea's own pinned nixpkgs,
      # since they need a concrete `pkgs` to build their own tooling. See
      # targets/default.nix for the actual per-target wiring.
      targets = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in import ./targets {
          inherit pkgs;
          mkTarget = self.lib.mkTarget;
          collectDeps = self.lib.collectDeps;
          targetImpl = self.lib.utils.targetImpl;
        }
      );
    };
}
