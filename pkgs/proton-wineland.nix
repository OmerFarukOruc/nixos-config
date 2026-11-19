{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261119";
  src = fetchurl {
    url = "https://github.com/nanomatters/proton-salkim/releases/download/wineland-${version}/proton-wineland-${version}-x86_64_v3.tar.xz";
    hash = "sha512-O60U3IGCh6P2cojN8pMrgaunNPFTFO9pO2cKzy29bU7R1v9t5U7fgWYuQeB6Kde63eq8jc/kk5Mmxrvj1ZVGLA==";
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
