# Two `resolve` bodies (see lib/mk-target.nix's `resolve` contract) that
# keep showing up verbatim across targets with no live registry to
# resolve against. Both are plain functions of `targetName` (used only
# for the generated derivation's own `name`) returning the actual
# `{ pkgs, deps }: <derivation>` -- no `lib` needed even at call time,
# since `pkgs.lib` is always available on whatever `pkgs` a `resolve` call
# receives (mkResolver always calls `resolve` with its own reliably
# -native pkgs, never necessarily a target's own -- see the comment in
# lib/resolver.nix).
{
  # Always emits an empty lock section, regardless of `deps` -- for a
  # target with no dependency-ecosystem concept at all (e.g. appimage,
  # tarball, docker: fully self-contained, nothing to resolve against).
  empty = targetName:
    { pkgs, deps }:
    pkgs.writeShellApplication {
      name = "resolve-${targetName}";
      text = "echo '{}'";
    };

  # Echoes the declared dependency spec back unchanged -- for a target
  # where `deps` is already fully resolved as declared (e.g. `nix`:
  # nixpkgs attribute names are already pinned by the nixpkgs revision in
  # use) or resolved externally, later, by something other than nixothea
  # (e.g. `aur`/`homebrew`: pacman/brew resolve dependencies themselves,
  # at install time, on the user's own machine).
  passthrough = targetName:
    { pkgs, deps }:
    pkgs.writeShellApplication {
      name = "resolve-${targetName}";
      text = "echo ${pkgs.lib.escapeShellArg (builtins.toJSON deps)}";
    };
}
