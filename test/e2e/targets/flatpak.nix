# End-to-end test of the `flatpak` target (targets/flatpak/): real
# manifest generation, checked structurally, plus a real `flatpak-builder`
# build against a real, locally-installed org.freedesktop.Platform/Sdk
# 24.08 (pulled from Flathub once while designing this test) -- unlike
# aur/homebrew, `flatpak-builder` genuinely is available and practical to
# run here (no `pacman`/`brew` needed, just the manifest plus a real
# installed runtime+sdk), so this target gets real build coverage, not
# just structural.
#
# `finish-args`/sandbox permissions default to empty (most restrictive --
# see targets/flatpak/default.nix's own header comment on why this isn't
# inferred), so the fixture app needs none: a real flatpak-builder build
# produces a real `.../files/bin/hello` inside the build directory, which
# is then run for real via `flatpak build` (the same sandboxed-execution
# mechanism `flatpak run` itself uses on an already-exported app), no
# `--share=network`/`--socket=*` required.
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  emptyLock = builtins.toFile "flatpak-lock.json" (builtins.toJSON { targets = { }; });

  appId = "invalid.nixothea.Hello";
  flatpakTarget = targets.flatpak {
    inherit appId;
    mainProgram = "hello";
    finishArgs = [ "--share=network" ];
  };

  shared = { pkgs }:
    pkgs.mkDerivation {
      pname = "shared-module"; version = "1.0";
      dontUnpack = true;
      buildPhase = "true";
      installPhase = ''
        mkdir -p /app/lib
        echo shared-module-marker > /app/lib/marker
      '';
    };

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildInputs = [ (shared { inherit pkgs; }) ];
      meta.description = "nixothea flatpak-target e2e fixture";
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        int main(void) { printf("flatpak hello\n"); return 0; }
        EOF
        cc hello.c -o hello
      '';
      installPhase = ''
        mkdir -p /app/bin
        cp hello /app/bin/hello
      '';
    };

  built = (buildTarget { targets.f = flatpakTarget; lockFile = emptyLock; inherit definition; }).f;

  mismatchedSourceThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.f = flatpakTarget;
      lockFile = emptyLock;
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "bad"; version = "1"; dontUnpack = true;
        flatpakSource = "https://example.invalid/bad.tar.gz"; # no flatpakSourceSha256
        buildPhase = "true"; installPhase = "true";
      };
    }).f.drvPath
    true)).success;

  dependencyThrew = !(builtins.tryEval (builtins.deepSeq
    (buildTarget {
      targets.f = flatpakTarget;
      lockFile = builtins.toFile "flatpak-lock-dep.json" (builtins.toJSON {
        targets.f = { zlib = { name = "zlib"; }; };
      });
      definition = { pkgs }: pkgs.mkDerivation {
        pname = "bad2"; version = "1"; dontUnpack = true;
        buildInputs = [ pkgs.zlib ];
        buildPhase = "true"; installPhase = "true";
      };
    }).f.drvPath
    true)).success;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-flatpak-structure"
      { flatpakOut = built; nativeBuildInputs = [ pkgs.jq ]; }
      ''
        manifest="$flatpakOut/${appId}.json"
        if [ ! -f "$manifest" ]; then
          echo "FAIL: no manifest produced" >&2
          exit 1
        fi
        # A real JSON parse -- toJSON is trusted to produce valid JSON by
        # construction, but this still confirms the file on disk really
        # is what got written, not a stale/truncated copy.
        if ! jq . "$manifest" > /dev/null; then
          echo "FAIL: manifest is not valid JSON" >&2
          cat "$manifest" >&2
          exit 1
        fi

        [ "$(jq -r '."app-id"' "$manifest")" = "${appId}" ] || { echo "FAIL: app-id" >&2; exit 1; }
        [ "$(jq -r '.runtime' "$manifest")" = "org.freedesktop.Platform" ] || { echo "FAIL: runtime" >&2; exit 1; }
        [ "$(jq -r '."runtime-version"' "$manifest")" = "24.08" ] || { echo "FAIL: runtime-version" >&2; exit 1; }
        [ "$(jq -r '.sdk' "$manifest")" = "org.freedesktop.Sdk" ] || { echo "FAIL: sdk" >&2; exit 1; }
        [ "$(jq -r '.command' "$manifest")" = "hello" ] || { echo "FAIL: command" >&2; exit 1; }
        [ "$(jq -r '."finish-args"[0]' "$manifest")" = "--share=network" ] || { echo "FAIL: finish-args" >&2; exit 1; }
        [ "$(jq -r '.modules | length' "$manifest")" = "2" ] || { echo "FAIL: modules count" >&2; exit 1; }
        [ "$(jq -r '.modules[0].name' "$manifest")" = "shared-module" ] || { echo "FAIL: modules[0] must be the nested node, not the root" >&2; exit 1; }
        [ "$(jq -r '.modules[1].name' "$manifest")" = "hello" ] || { echo "FAIL: modules[1] must be the root" >&2; exit 1; }
        if ! jq -e '.modules[0]."build-commands"[1] | test("shared-module-marker")' "$manifest" > /dev/null; then
          echo "FAIL: shared-module's own install command missing from its module entry" >&2
          cat "$manifest" >&2
          exit 1
        fi

        echo "nixothea-test-target-flatpak-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-flatpak-run";
    runtimeInputs = [ pkgs.flatpak pkgs.flatpak-builder ];
    text = ''
      # Uses the real invoking user's own `--user` Flatpak installation
      # (not a fresh scratch $HOME) so the runtime/SDK download -- a
      # real, ~1-2GiB fetch from Flathub -- is a one-time cost across
      # repeated runs, the same way docker/snap/deb/apk/dnf*'s own apps
      # reuse the host's real podman storage rather than a throwaway one.
      flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
      flatpak --user install -y --noninteractive flathub org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08

      # --state-dir explicit and on the same filesystem as $builddir:
      # flatpak-builder's default state dir is relative to the caller's
      # cwd, and hardlinking its cache against a build dir on a different
      # filesystem (e.g. a repo checkout on a real disk vs. a /tmp
      # tmpfs) fails outright -- confirmed by hand while designing this.
      # --disable-rofiles-fuse: flatpak-builder's default cache strategy
      # bind-mounts a FUSE overlay (rofiles-fuse) over the build dir --
      # confirmed by hand while designing this that fails outright here
      # ("mount failed: Operation not permitted") even though /dev/fuse
      # itself exists (same class of sandboxed-privilege gap as podman's
      # own rootless setup needing extra flags elsewhere in this suite).
      # Without it, flatpak-builder just copies instead of hardlinking
      # through the overlay -- slower, not less correct.
      scratch="$(mktemp -d)"
      builddir="$scratch/build"
      flatpak-builder --force-clean --user --install-deps-from=flathub \
        --disable-rofiles-fuse \
        --state-dir="$scratch/state" "$builddir" ${built}/${appId}.json

      actual=$(flatpak build "$builddir" hello)
      echo "flatpak payload printed (inside a real flatpak-builder build dir): $actual"
      case "$actual" in
        "flatpak hello") : ;;
        *) echo "FAIL: unexpected output: $actual" >&2; exit 1 ;;
      esac
      echo "nixothea-test-target-flatpak-run: passed"
    '';
  };
} // (
  if !mismatchedSourceThrew then
    throw "nixothea e2e flatpak-target: expected a throw for flatpakSource set without flatpakSourceSha256, none happened"
  else if !dependencyThrew then
    throw "nixothea e2e flatpak-target: expected a throw when a declared dependency is used (unsupported), none happened"
  else
    { }
)
