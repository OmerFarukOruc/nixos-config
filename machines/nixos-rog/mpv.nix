{
  config,
  lib,
  pkgs,
  ...
}:
let
  scheme = config.scheme.withHashtag;

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
      hwdec = "vulkan-copy,vaapi-copy";
      osc = false;
      osd-color = scheme.base05;
      osd-border-color = scheme.base00;
    };
    scriptOpts.modernz = {
      osc_color = scheme.base00;
      window_title_color = scheme.base05;
      window_controls_color = scheme.base05;
      windowcontrols_close_hover = scheme.base08;
      windowcontrols_max_hover = scheme.base0A;
      windowcontrols_min_hover = scheme.base0B;
      title_color = scheme.base05;
      cache_info_color = scheme.base05;
      seekbar_cache_color = scheme.base03;
      seekbarfg_color = scheme.base0D;
      seekbarbg_color = scheme.base02;
      seek_handle_color = scheme.base0D;
      seek_handle_border_color = scheme.base05;
      time_color = scheme.base05;
      chapter_title_color = scheme.base05;
      side_buttons_color = scheme.base05;
      middle_buttons_color = scheme.base05;
      playpause_color = scheme.base05;
      held_element_color = scheme.base03;
      hover_effect_color = scheme.base0D;
      thumbnail_box_color = scheme.base01;
      thumbnail_box_outline = scheme.base03;
      nibble_color = scheme.base0D;
      nibble_current_color = scheme.base05;
      ab_loop_color = scheme.base0C;
    };
  };

  home.packages = [
    (pkgs.writeShellScriptBin "mpv-nvidia" ''
      VK_LOADER_DRIVERS_SELECT='*nvidia*' exec nvidia-offload ${lib.getExe config.programs.mpv.finalPackage} --hwdec=auto-copy "$@"
    '')
  ];

  xdg.mimeApps.defaultApplications = lib.genAttrs mimeTypes (_: [ "mpv.desktop" ]);
}
