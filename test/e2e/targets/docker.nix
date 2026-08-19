# End-to-end test of the `docker` target (targets/docker/): real
# `dockerTools.buildLayeredImage` build, with `exposedPorts`/`labels`/
# `env`/`cmd` all set so the real generated OCI config can be checked for
# real content, not just that a tarball exists.
#
# The `checks.*` half stops at structural validation (real image, real
# extracted config.json) -- actually `docker load`/`run`ning the image
# needs a container engine, and real rootless podman was confirmed (by
# hand, while designing this) to work fine as a plain host process but to
# fail nested inside Nix's own build sandbox (missing /etc/subuid and
# other privilege-adjacent setup a sandboxed build doesn't have) -- so the
# actual "load it for real and run it for real, check real stdout" proof
# is `apps.test-target-docker-run` instead (`nix run`-able, real host
# process, real podman, no sandbox).
{ pkgs, targets }:
let
  lib = pkgs.lib;
  buildTarget = import ../../../lib/build.nix;
  emptyLock = builtins.toFile "docker-lock.json" (builtins.toJSON { targets = { }; });

  dockerTarget = targets.docker {
    imageName = "nixothea-e2e-hello";
    tag = "test";
    cmd = [ "extra-arg" ];
    env = [ "GREETING=hi" ];
    exposedPorts = [ "8080/tcp" ];
    labels = { "org.nixothea.test" = "true"; };
  };

  definition = { pkgs }:
    pkgs.mkDerivation {
      pname = "hello"; version = "1.0";
      dontUnpack = true;
      buildPhase = ''
        cat > hello.c <<'EOF'
        #include <stdio.h>
        #include <stdlib.h>
        int main(void) {
          const char *g = getenv("GREETING");
          printf("docker says: %s\n", g ? g : "(unset)");
          return 0;
        }
        EOF
        $CC hello.c -o hello
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/hello
      '';
    };

  built = (buildTarget { targets.d = dockerTarget; lockFile = emptyLock; inherit definition; }).d;
in
{
  checks = {
    structure = pkgs.runCommand "nixothea-test-target-docker-structure"
      { imageTar = built; nativeBuildInputs = [ pkgs.gnutar pkgs.jq ]; }
      ''
        mkdir extracted
        tar -xzf "$imageTar" -C extracted
        if [ ! -f extracted/manifest.json ]; then
          echo "FAIL: no manifest.json in the built image" >&2
          exit 1
        fi
        configFile=$(jq -r '.[0].Config' extracted/manifest.json)
        if [ ! -f "extracted/$configFile" ]; then
          echo "FAIL: manifest.json references a config blob that doesn't exist: $configFile" >&2
          exit 1
        fi
        config="extracted/$configFile"

        entrypoint=$(jq -r '.config.Entrypoint[0]' "$config")
        case "$entrypoint" in
          */bin/hello) : ;;
          *) echo "FAIL: unexpected Entrypoint: $entrypoint" >&2; exit 1 ;;
        esac

        if [ "$(jq -r '.config.Cmd[0]' "$config")" != "extra-arg" ]; then
          echo "FAIL: Cmd didn't round-trip" >&2; exit 1
        fi
        if [ "$(jq -r '.config.Env[0]' "$config")" != "GREETING=hi" ]; then
          echo "FAIL: Env didn't round-trip" >&2; exit 1
        fi
        if ! jq -e '.config.ExposedPorts["8080/tcp"]' "$config" > /dev/null; then
          echo "FAIL: ExposedPorts didn't round-trip" >&2; exit 1
        fi
        if [ "$(jq -r '.config.Labels."org.nixothea.test"' "$config")" != "true" ]; then
          echo "FAIL: Labels didn't round-trip" >&2; exit 1
        fi

        echo "nixothea-test-target-docker-structure: passed" > $out
      '';
  };

  apps.run = pkgs.writeShellApplication {
    name = "nixothea-test-target-docker-run";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-$(mktemp -d)}"
      echo "loading ${built} ..."
      podman load -i ${built}
      actual=$(podman run --rm localhost/nixothea-e2e-hello:test)
      echo "container printed: $actual"
      if [ "$actual" != "docker says: hi" ]; then
        echo "FAIL: expected 'docker says: hi', got '$actual'" >&2
        exit 1
      fi
      podman rmi localhost/nixothea-e2e-hello:test > /dev/null
      echo "nixothea-test-target-docker-run: passed"
    '';
  };
}
