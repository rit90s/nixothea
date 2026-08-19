# Unit tests for utils/targetImpl/license-names.nix -- normalizing
# meta.license-shaped values into a flat list of plain strings.
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  licenseNames = import ../../utils/targetImpl/license-names.nix;
in
[
  { name = "null license normalizes to []"; expr = licenseNames { inherit lib; license = null; }; expected = [ ]; }
  { name = "a plain string passes through as a single-element list"; expr = licenseNames { inherit lib; license = "MIT"; }; expected = [ "MIT" ]; }
  {
    name = "a nixpkgs-style license attrset uses spdxId when present";
    expr = licenseNames { inherit lib; license = { spdxId = "MIT"; shortName = "mit"; fullName = "MIT License"; }; };
    expected = [ "MIT" ];
  }
  {
    name = "a license attrset with only shortName falls back to it";
    expr = licenseNames { inherit lib; license = { shortName = "mit"; }; };
    expected = [ "mit" ];
  }
  {
    name = "a license attrset with neither spdxId nor shortName drops out entirely";
    expr = licenseNames { inherit lib; license = { fullName = "Some License"; }; };
    expected = [ ];
  }
  {
    name = "a list of mixed strings/attrsets normalizes each element, dropping ones with nothing usable";
    expr = licenseNames {
      inherit lib;
      license = [ "MIT" { spdxId = "Apache-2.0"; } { fullName = "no id at all"; } ];
    };
    expected = [ "MIT" "Apache-2.0" ];
  }
]
