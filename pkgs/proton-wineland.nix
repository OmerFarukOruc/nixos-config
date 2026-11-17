{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261117";
  src = fetchurl {
    url = "https://github.com/nanomatters/proton-salkim/releases/download/wineland-${version}/proton-wineland-${version}-x86_64_v3.tar.xz";
    hash = "sha512-Jm4AnGFGmIiUhZsGiFf8+P8cN3mHLrm+WPsV/C9UDN3mRFoGj5EB9mFCudrh0gsxffVl6g/nV3NMIPDe5EYbpQ==";
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
