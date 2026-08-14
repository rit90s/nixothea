# A constructor: `nixothea.targets.homebrew { }` returns a target that
# produces a Homebrew Formula (a Ruby recipe file) -- like the aur target,
# nixothea never compiles the real software for this target, only
# generates the recipe. The real compile happens later, for real, when
# `brew install` runs the Formula's `install do` block on the user's own
# machine (Homebrew supports both macOS and Linux -- "Homebrew on Linux").
# This sidesteps the practical problem a self-built binary target would
# have here: genuine Linux->Darwin cross-compilation isn't a well-
# supported path in nixpkgs the way mingw is for Windows, and this way
# nixothea never needs a real Darwin builder at all -- the user's own
# `brew install` does the real compiling on their own machine, exactly
# like virtually every real-world Formula already works.
#
# Unlike aur, a Formula's `url`/`sha256` genuinely can't be omitted --
# Homebrew's Formula class structurally requires a fetchable source
# (unlike a PKGBUILD, which is happy to run build()/package() against
# nothing) -- so homebrewSource/homebrewSourceSha256 (set alongside
# pname/version/meta/buildPhase/installPhase on the pkgs.mkDerivation
# call, same convention as aur.nix's aurSource/aurSourceSha256) are
# mandatory here, not optional-but-paired.
#
# Known limitations, kept out of scope for this pass:
#   - no build-only/runtime dependency distinction -- every declared
#     dependency becomes a plain runtime `depends_on`;
#   - a dependency's versionConstraint (see mk-target.nix) has no
#     representable equivalent in a plain `depends_on "name"` and is
#     silently ignored;
#   - no auto-generated `test do` block (brew audit wants one for real
#     tap submissions, but it's not required for `brew install` to work);
#   - class-name sanitization doesn't replicate Homebrew's own leading
#     -digit naming convention (see builder.nix's className);
#   - the embedded shell text is spliced into a Ruby squiggly heredoc
#     (<<~) -- a buildPhase/installPhase that happens to contain the
#     literal two characters "#{" (Ruby interpolation syntax) would be
#     misinterpreted; not sanitized against here, same class of trust-the-
#     caller-supplied-text tradeoff as every other target's templating.
{ pkgs, mkTarget, collectDeps, targetImpl }:
let
  lib = pkgs.lib;
in
{
  # Independently incremented when only the packaging (not the underlying
  # software) changes -- Homebrew's own name for exactly the concept
  # aur.nix's pkgrel covers.
  revision ? null,
}:
mkTarget {
  inherit pkgs lib;
  resolve = targetImpl.resolvers.passthrough "homebrew";
  inherit (import ./builder.nix { inherit lib collectDeps revision targetImpl; })
    nativeDerivationFactory mkDerivation;
}
