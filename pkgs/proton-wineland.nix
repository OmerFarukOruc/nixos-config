{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261124";
  src = fetchurl {
    url = "https://github.com/nanomatters/proton-salkim/releases/download/wineland-${version}/proton-wineland-${version}-x86_64_v3.tar.xz";
    hash = "sha512-a2N87pF3V035ihx3qWDv72bTGhn+Le7tkOUa/cT6j2ivdlcIRCRoRVyMXD6V2nBwsaheFSY7xXa5VG9yEmyiBA==";
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
