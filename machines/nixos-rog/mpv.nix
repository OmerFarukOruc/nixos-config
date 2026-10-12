# mpv on the Radeon 890M, with an mpv-nvidia wrapper for the RTX 4070.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Opening the RTX 4070 wakes it, and the Vulkan loader opens every driver it
  # finds, VA-API the first render node. Plain mpv sees only the Radeon's
  # Vulkan driver and render node; mpv-nvidia sees only NVIDIA's driver.
  radeonRenderNode = import ./radeon-render-node.nix;

  mimeTypes = [
    "audio/aac"
    "audio/flac"
    "audio/mp4"
    "audio/mpeg"
    "audio/ogg"
    "audio/opus"
    "audio/wav"
    "audio/webm"
    "audio/x-flac"
    "audio/x-matroska"
    "audio/x-vorbis+ogg"
    "audio/x-wav"
    "video/mp4"
    "video/mpeg"
    "video/ogg"
    "video/quicktime"
    "video/webm"
    "video/x-flv"
    "video/x-matroska"
    "video/x-msvideo"
  ];
in
{
  programs.mpv = {
    enable = true;
    extraMakeWrapperArgs = [
      "--set-default"
      "VK_LOADER_DRIVERS_SELECT"
      "*radeon*"
    ];
    scripts = with pkgs.mpvScripts; [
      # keep-sorted start
      dynamic-crop
      modernz
      mpris
      thumbfast
      # keep-sorted end
    ];
    config = {
      vo = "gpu-next";
      gpu-api = "vulkan";
      gpu-context = "waylandvk";
      vaapi-device = radeonRenderNode;
      target-colorspace-hint = true;
      scale = "ewa_lanczossharp";
      cscale = "ewa_lanczossharp";
      # Only decoders on the Radeon; auto-copy would fall back to NVDEC.
      hwdec = "vulkan-copy,vaapi-copy";
      # ModernZ draws the on-screen controller instead.
      osc = false;
    };
  };

  # HDR through PRIME is untested.
  home.packages = [
    (pkgs.writeShellScriptBin "mpv-nvidia" ''
      VK_LOADER_DRIVERS_SELECT='*nvidia*' exec nvidia-offload ${lib.getExe config.programs.mpv.finalPackage} --hwdec=auto-copy "$@"
    '')
  ];

  xdg.mimeApps.defaultApplications = lib.genAttrs mimeTypes (_: [ "mpv.desktop" ]);
}
