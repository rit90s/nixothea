# Builds the merged payload/ tree that becomes the snap's own content --
# see default.nix's header comment for why bundling (not just declaring
# and trusting, the way deb's Depends: line can get away with) is
# necessary here.
{ pkgs, lib, realDrv, allPayloads, allDependencyDerivations, targetInterpreter }:
pkgs.stdenv.mkDerivation {
  pname = "${realDrv.pname}-snap-payload";
  version = realDrv.version;
  dontUnpack = true;
  # Unlike deb (whose equivalent patching happens against a throwaway
  # build-dir, with only the final *packed* .deb blob ever reaching
  # $out, which Nix's fixupPhase can't see into), this derivation's $out
  # is the raw, loose payload tree itself -- so the default fixupPhase's
  # own patchShebangs would rescan and silently revert the
  # interpreter-path fix below. Verified empirically: without this, a
  # script's shebang gets rewritten back to the Nix store path
  # patchShebangs originally set, right after this buildPhase had just
  # fixed it. Same reasoning as appimage.nix's dontFixup: nothing here
  # benefits an artifact meant to run unmodified outside Nix anyway.
  dontFixup = true;
  nativeBuildInputs = [ pkgs.patchelf ];
  buildPhase = ''
    runHook preBuild
    mkdir -p payload

    ${lib.concatMapStringsSep "\n" (p: ''
      cp -a --no-preserve=ownership ${p}/. payload/
      chmod -R u+w payload
    '') allPayloads}

    # Retargets our own built binaries from Nix's dynamic linker to the
    # base snap's real one (see default.nix's header comment for why
    # this isn't optional), and drops the Nix-store RPATH entries
    # bintools-wrapper added for buildInputs -- once removed, the loader
    # falls through to snapd's own default LD_LIBRARY_PATH for
    # strict-confinement apps, which is exactly where the bundled
    # dependency libraries below end up. Left untouched: the
    # dependency-derivation content copied in next never enters this
    # loop (only allPayloads -- our own realDrv/nested-node outputs --
    # do), so nothing here is foreign, already-correctly-linked Ubuntu
    # content.
    find payload -type f | while read -r f; do
      if patchelf --print-rpath "$f" >/dev/null 2>&1; then
        patchelf --remove-rpath "$f" || true
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter "${targetInterpreter}" "$f"
        fi
      fi
    done

    # The exact same problem appimage.nix's AppRun generation had to
    # solve, for the exact same reason: realDrv's own (normal,
    # non-dontFixup'd) build already ran patchShebangs, which rewrites
    # e.g. a plain "#!/bin/sh" into an absolute /nix/store/...-bash.../
    # bin/sh -- a path the base snap's mount namespace doesn't contain
    # either. Verified empirically (a real shell-script mainProgram
    # genuinely ships this broken shebang without this fix).
    # patchShebangs preserves the original interpreter's basename when
    # it rewrites, so reconstructing "/usr/bin/<basename>" is a real,
    # correct fix for the common case (a base snap's minimal Ubuntu
    # userspace has /usr/bin/sh, /usr/bin/bash) -- not a general fix for
    # an arbitrary interpreter the base doesn't ship (e.g. python3),
    # which would need appimage.nix's full closure-bundling treatment to
    # solve properly; out of scope here, documented as a known gap. Only
    # matches files whose first line literally starts with
    # "#!/nix/store/" -- an ELF binary's first bytes are "\x7fELF",
    # never "#!", so this can't misfire on the ELF payloads the loop
    # above handles.
    find payload -type f | while read -r f; do
      first_line=$(head -c 512 "$f" 2>/dev/null | head -n1)
      case "$first_line" in
        "#!${builtins.storeDir}"/*)
          interp_path=''${first_line#\#!}
          interp_bin=''${interp_path%% *}
          interp_args=''${interp_path#"$interp_bin"}
          interp_name=$(basename "$interp_bin")
          sed -i "1s|.*|#!/usr/bin/$interp_name$interp_args|" "$f"
          ;;
      esac
    done

    # Runtime library dependencies: bundled directly into the payload,
    # not just declared and trusted -- see default.nix's header comment
    # for why deb's Depends:-only approach doesn't carry over to a
    # strict-confinement snap. Left unpatched, same reasoning as deb's
    # own dontFixup'd dependency derivation: these are already-correct
    # real Ubuntu binaries, built for the exact same base/suite this
    # snap targets. Only usr/ is copied (not the top-level include/lib
    # convenience symlinks extracted-dependency.pkg.nix adds for Nix's
    # own cc-wrapper) -- bundles a dependency's -dev headers/pkgconfig/
    # static-lib content too, alongside the runtime .so, since both live
    # in the same merged derivation; harmless bloat, not a correctness
    # bug, documented as a known gap.
    ${lib.concatMapStringsSep "\n" (d: ''
      mkdir -p payload/usr
      cp -a --no-preserve=ownership ${d}/usr/. payload/usr/
      chmod -R u+w payload
    '') allDependencyDerivations}

    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    cp -a payload $out
    runHook postInstall
  '';
}
