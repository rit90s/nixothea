# Normalizes a `meta.license`-shaped value -- a plain string, a nixpkgs
# -style license attrset (`.spdxId`/`.shortName`, e.g. anything from
# `lib.licenses.*`), or a list of either -- into a flat list of plain
# strings, dropping anything that normalizes to nothing (e.g. a license
# attrset with neither `spdxId` nor `shortName` set). Joining that list
# into a target's own native syntax (a PKGBUILD/Formula/`.PKGINFO`
# license line, an `AND`-joined SPDX expression, ...) is left to the
# target itself -- that part genuinely differs per format. `lib` is a
# call-time argument, not bound at import time -- same convention as
# lib/collect-deps.nix.
{ lib, license }:
let
  single = l: if builtins.isString l then l else (l.spdxId or l.shortName or null);
in
if license == null then [ ]
else if builtins.isList license then lib.filter (x: x != null) (map single license)
else lib.filter (x: x != null) [ (single license) ]
