{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261127";
  src = fetchurl {
    url = "https://github.com/nanomatters/proton-salkim/releases/download/wineland-${version}/proton-wineland-${version}-x86_64_v3.tar.xz";
    hash = "sha512-1EpUX6Yuo3mSSNHS9kqqwxkZFHYxIjVP9ioU1QjWzJzjz1wuotIt5KLtyL4bpgygJBRTOyw3gG1ZZP8VqmDstw==";
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
