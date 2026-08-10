# Official type-2 AppImage runtime stub, prepended to the squashfs
# payload to make the result directly executable. nixpkgs doesn't
# package this -- pkgs.appimageTools only wraps/extracts *existing*
# AppImages (for running them on NixOS), it has no support for building
# new ones, and there's no appimagetool/mkappimage/appimage-builder in
# nixpkgs either. Pinned to a dated release (not the floating
# "continuous" tag) so the fetch stays reproducible.
{ pkgs }:
pkgs.fetchurl {
  url = "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64";
  sha256 = "0396xi3km1yd0z4329lbjxmv82ddc40gd0x8hca0ylcj7i28pjig";
}
