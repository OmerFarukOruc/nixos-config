# colgrep, semantic code search with a local search agent, from the prebuilt
# Linux release of lightonai/next-plaid. That build has the CUDA encoder.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  openssl,
  cudaPackages_12,
  addDriverRunpath,
}:
let
  # On first use colgrep downloads ONNX Runtime 1.23.0 for CUDA 12 and dlopens
  # it; its CUDA provider needs these libraries, and colgrep uses the GPU only
  # when it finds libcudnn.so.9 on LD_LIBRARY_PATH.
  cudaLibs = with cudaPackages_12; [
    cuda_cudart
    cuda_nvrtc
    cudnn
    libcublas
    libcufft
    libcurand
  ];
in
stdenv.mkDerivation rec {
  pname = "colgrep";
  version = "1.8.5";

  src = fetchurl {
    url = "https://github.com/lightonai/next-plaid/releases/download/v${version}/colgrep-x86_64-unknown-linux-gnu.tar.xz";
    hash = "sha256-Uy4dpzn2tdSJza79IMWRj6G7D/n0VsiQmOtJpjea4gU=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [
    openssl
    stdenv.cc.cc.lib
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 colgrep $out/bin/colgrep
    runHook postInstall
  '';

  # The downloaded ONNX Runtime also needs libstdc++ and the driver's libcuda.
  # Vulkan device 0 is the RTX 4070 in hybrid mode and the Radeon 890M in
  # integrated mode; without it the agent picks the GPU with the most free
  # memory, which is the 890M's share of system memory.
  postFixup = ''
    wrapProgram $out/bin/colgrep \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath (cudaLibs ++ [ stdenv.cc.cc.lib ])
      }:${addDriverRunpath.driverLink}/lib \
      --set-default GGML_VK_VISIBLE_DEVICES 0
  '';

  meta = {
    description = "Semantic code search for the terminal and coding agents";
    homepage = "https://github.com/lightonai/next-plaid";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "colgrep";
  };
}
