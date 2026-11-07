{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261106";
  src = fetchurl {
    url = "https://github.com/nanomatters/proton-salkim/releases/download/wineland-${version}/proton-wineland-${version}-x86_64_v3.tar.xz";
    hash = "sha512-jYxfHj2rUxCrBwSeiIIpFED/Qg4FpTGIPt2uWJSNXCduELltEH5CMBIIwf10S3vBZliREcFb5ZJvH3xa6RZvsw==";
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
