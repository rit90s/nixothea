# Shared implementation behind every target's "which binary under
# $out/bin/ is the entry point" option (appimage/tarball/docker/snap's
# `mainProgram`, windowsExe/windowsMsi's `mainProgram`, ...): if the
# caller set one explicitly, use it; otherwise require exactly one
# candidate under `${realDrv}/bin` and use that, or throw asking for it
# to be set explicitly. `lib` is a call-time argument, not bound at
# import time -- same convention as lib/collect-deps.nix -- so this stays
# usable from `nixothea.lib.utils.targetImpl` with whatever `lib` the
# caller already has in scope.
{
  lib,

  # For error messages only, e.g. "appimage" -> "nixothea appimage target: ...".
  targetName,

  # The built derivation whose $out/bin/ to inspect. Only ever actually
  # read (via string interpolation, forcing a real build) when
  # `mainProgram` is null.
  realDrv,

  # The caller-supplied override, or null to auto-detect.
  mainProgram,

  # When set (e.g. ".exe" for windowsExe/windowsMsi), only files under
  # bin/ with this suffix are considered, and the suffix is stripped from
  # the resolved name. When null (the default), every entry under bin/ is
  # a candidate and the resolved name is used as-is.
  matchSuffix ? null,

  # Spliced into "set mainProgram<extraHelp> explicitly" in both error
  # messages -- e.g. " or entrypoint" for docker, which has a second way
  # to sidestep auto-detection entirely.
  extraHelp ? "",
}:
if mainProgram != null then
  mainProgram
else if !(builtins.pathExists "${realDrv}/bin") then
  throw "nixothea ${targetName} target: ${realDrv.pname} has no bin/ directory -- set mainProgram${extraHelp} explicitly"
else
  let
    allEntries = builtins.attrNames (builtins.readDir "${realDrv}/bin");
    candidates =
      if matchSuffix == null then allEntries
      else builtins.filter (lib.hasSuffix matchSuffix) allEntries;
    kind = if matchSuffix == null then "binaries" else "${matchSuffix} file(s)";
  in
  if builtins.length candidates == 1 then
    (if matchSuffix == null then builtins.head candidates
     else lib.removeSuffix matchSuffix (builtins.head candidates))
  else
    throw "nixothea ${targetName} target: ${realDrv.pname} ships ${toString (builtins.length candidates)} ${kind} under bin/ -- set mainProgram${extraHelp} explicitly"
