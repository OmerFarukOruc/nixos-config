{
  callPackage,
  fetchurl,
}:
let
  version = "11.0-20261015-slr";
  src = fetchurl {
    url = "https://github.com/CachyOS/proton-cachyos/releases/download/cachyos-${version}/proton-cachyos-${version}-x86_64_v3.tar.xz";
    hash = "sha512-w9McfZAFBJsfrnhA0/uaA0g5+ZHlNyQWqSAGCLDIFUH4U7ueZVyROK6J58xpNcij/ymJCBP47zHXIjFQ1gTuBg==";
  };
in
callPackage ./proton-tarball {
  pname = "proton-cachyos";
  inherit version src;
  steamDisplayName = "Proton-CachyOS";
  homepage = "https://github.com/CachyOS/proton-cachyos";
  description = "CachyOS's Proton build, with OptiScaler and the DXVK and VKD3D low-latency options";
  passthru.githubRepo = "CachyOS/proton-cachyos";
  passthru.releaseTagPrefix = "cachyos-";
}
