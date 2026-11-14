{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261114";
  src = fetchurl {
    url = "https://github.com/nanomatters/proton-salkim/releases/download/wineland-${version}/proton-wineland-${version}-x86_64_v3.tar.xz";
    hash = "sha512-K4b0p9b6cvdsai3Vv9ReUGV3Wpj9oWl+2l4Trfl0UFdy1eTam7flhkGY7qtbL8HwLXzv+E0rJK+noJ3pWrM6JQ==";
  };
in
callPackage ./proton-tarball {
  pname = "proton-wineland";
  inherit version src;
  steamDisplayName = "Proton-Wineland";
  homepage = "https://github.com/nanomatters/proton-salkim";
  description = "Proton build that fixes Wayland problems of Windows launchers, fullscreen windows and overlays";
  passthru.githubRepo = "nanomatters/proton-salkim";
  passthru.releaseTagPrefix = "wineland-";
}
