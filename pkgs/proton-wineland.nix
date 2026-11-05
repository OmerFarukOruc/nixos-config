{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261103";
  src = fetchurl {
    url = "https://github.com/nanomatters/proton-salkim/releases/download/wineland-${version}/proton-wineland-${version}-x86_64_v3.tar.xz";
    hash = "sha512-b4LzJMevddEUxihGVsyaGIa8a6fVb63sH932mPc8D8WsBy46H+1Up81jVHuPrrKh0y1N7yJeSuw9Vg2wwAJcCA==";
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
