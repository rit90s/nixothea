# Unit tests for utils/same-entry.nix -- string/full-entry normalization,
# per-target overrides replacing (not merging with) the default, both
# `targets` shapes (list or attrset), and the typo-detection throws. See
# doc/utils/same-entry.md; these cases mirror what was verified by hand
# against real `nix eval` output while designing the function.
{ pkgs, fixtures }:
let
  lib = pkgs.lib;
  sameEntry = import ../../utils/same-entry.nix;
in
[
  {
    name = "string shorthand normalizes to { name = ...; } on every target";
    expr = sameEntry {
      inherit lib;
      targets = [ "a" "b" ];
      default = { zlib = "zlib"; };
    };
    expected = { zlib = { a = { name = "zlib"; }; b = { name = "zlib"; }; }; };
  }
  {
    name = "a full entry attrset in default is used as-is, not re-wrapped";
    expr = sameEntry {
      inherit lib;
      targets = [ "a" ];
      default = { openssl = { name = "openssl"; version = "3.0.0"; }; };
    };
    expected = { openssl = { a = { name = "openssl"; version = "3.0.0"; }; }; };
  }
  {
    name = "an override replaces the default entirely for that one target, other targets keep the default";
    expr = sameEntry {
      inherit lib;
      targets = [ "a" "b" ];
      default = { zlib = "zlib"; };
      overrides.a.zlib = "zlib1g-dev";
    };
    expected = { zlib = { a = { name = "zlib1g-dev"; }; b = { name = "zlib"; }; }; };
  }
  {
    name = "targets accepts a plain list of names";
    expr = builtins.attrNames (sameEntry { inherit lib; targets = [ "x" "y" ]; default = { d = "d"; }; }).d;
    expected = [ "x" "y" ];
  }
  {
    name = "targets accepts an attrset (only attrNames used)";
    expr = builtins.attrNames (sameEntry { inherit lib; targets = { x = { }; y = { }; }; default = { d = "d"; }; }).d;
    expected = [ "x" "y" ];
  }
  {
    name = "overrides naming a target not in targets throws";
    expr = sameEntry {
      inherit lib;
      targets = [ "a" ];
      default = { zlib = "zlib"; };
      overrides.typoTarget.zlib = "zlib1g-dev";
    };
    throws = true;
  }
  {
    name = "overrides naming a logical name not in default throws";
    expr = sameEntry {
      inherit lib;
      targets = [ "a" ];
      default = { zlib = "zlib"; };
      overrides.a.typoName = "zlib1g-dev";
    };
    throws = true;
  }
]
