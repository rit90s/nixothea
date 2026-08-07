# A constructor: `nixothea.targets.aur { }` returns a target that produces
# a PKGBUILD -- AUR packages are metadata plus a build recipe makepkg runs
# later, externally, on a real Arch machine (which is what actually
# fetches sources and installs dependencies via pacman) -- nixothea never
# builds the real software for this target, only generates the recipe.
#
# Known limitations, kept out of scope for this pass:
#   - no source= / sha256sums= generation -- package definitions targeting
#     this should describe their build entirely through buildPhase/
#     installPhase (as all the other targets' tests in this repo do; no
#     dependence on Nix's own source fetchers);
#   - no makedepends= -- nativeBuildInputs stays real Nix build tooling
#     (see wrap-mk-derivation.nix), which isn't meaningful to write into a
#     PKGBUILD meant to run on a real Arch machine;
#   - pkgname/pkgver aren't validated against PKGBUILD's charset rules.
{ pkgs, mkTarget, collectDeps }:
let
  lib = pkgs.lib;

  licenseName = l: if builtins.isString l then l else (l.spdxId or l.shortName or null);
  licenseNames = l:
    if l == null then [ ]
    else if builtins.isList l then lib.filter (x: x != null) (map licenseName l)
    else lib.filter (x: x != null) [ (licenseName l) ];
in
{
  # PKGBUILD header comment, e.g. "Name <email>". Omitted when null.
  maintainer ? null,

  # Incremented independently of pkgver when only the packaging (not the
  # underlying software) changes.
  pkgrel ? 1,

  arch ? [ "x86_64" ],
}:
mkTarget {
  inherit lib;

  # No live registry to resolve against here (unlike a real repo target,
  # e.g. deb/rpm) -- pacman/AUR resolve dependencies themselves, later, at
  # install time -- so this just echoes the declared dependency spec back
  # as the lock section, unchanged.
  resolve = { pkgs, deps }:
    pkgs.writeShellApplication {
      name = "resolve-aur";
      text = "echo ${lib.escapeShellArg (builtins.toJSON deps)}";
    };

  # Pure metadata -- no real derivation. entry.name is the real
  # (AUR-or-official-repo) package name; entry.versionConstraint, if set,
  # is an Arch-style constraint suffix (e.g. ">=3.0") appended directly to
  # the name in the generated depends= entry.
  nativeDerivationFactory = { pkgs, name, entry }:
    {
      pkgName = entry.name;
      versionConstraint = entry.versionConstraint or null;
    };

  mkDerivation = { pkgs, role, name ? null, realDrv, nodeDeps, dependencyDeps, args }:
    if role == "dependency" then
      # Never actually realized (see below) -- exists only so the
      # framework has something to hand back if anything ever calls this
      # node with role = "dependency" directly, rather than folding it in
      # structurally the way role = "root" below does via collectDeps.
      realDrv
    else if role == "root" then
      let
        collected = collectDeps { inherit lib; nodes = nodeDeps; };

        # collected.dependencies only covers dependencies found on nested
        # nodes (reached by walking nodeDeps) -- the root's *own* direct
        # dependencyDeps aren't part of that walk, so they're merged in
        # separately here, deduplicated the same way collectDeps dedupes
        # (by the logical name a dependency was declared under).
        allDependencies = builtins.attrValues (builtins.listToAttrs
          (map (d: { name = d._nixotheaDependencyName; value = d; })
            (dependencyDeps ++ collected.dependencies)));

        # "One combined package": every transitively-reachable node's own
        # build/install steps, followed by the root's own -- concatenated
        # in collectDeps' order, not real dependency order (this is a
        # naive merge, not a topological one).
        steps = phase: map (n: n.args.${phase} or "") collected.nodes ++ [ (args.${phase} or "") ];

        depLine = d:
          lib.escapeShellArg (d.pkgName + (if d.versionConstraint or null == null then "" else d.versionConstraint));

        meta = args.meta or { };
        licenses = licenseNames (meta.license or null);

        pkgbuild = pkgs.writeText "PKGBUILD" ''
          ${lib.optionalString (maintainer != null) "# Maintainer: ${maintainer}"}
          pkgname=${args.pname}
          pkgver=${args.version}
          pkgrel=${toString pkgrel}
          ${lib.optionalString (meta ? description) "pkgdesc=${lib.escapeShellArg meta.description}"}
          arch=(${lib.concatMapStringsSep " " lib.escapeShellArg arch})
          ${lib.optionalString (meta ? homepage) "url=${lib.escapeShellArg meta.homepage}"}
          ${lib.optionalString (licenses != [ ]) "license=(${lib.concatMapStringsSep " " lib.escapeShellArg licenses})"}
          ${lib.optionalString (allDependencies != [ ]) "depends=(${lib.concatMapStringsSep " " depLine allDependencies})"}

          build() {
            cd "$srcdir"
          ${lib.concatStringsSep "\n" (steps "buildPhase")}
          }

          package() {
            out="$pkgdir/usr"
            mkdir -p "$out"
            cd "$srcdir"
          ${lib.concatStringsSep "\n" (steps "installPhase")}
          }
        '';
      in
      pkgs.runCommand "${args.pname}-aur" { } ''
        mkdir -p $out
        cp ${pkgbuild} $out/PKGBUILD
      ''
    else
      throw "nixothea aur target: unknown role ${role}";
}
