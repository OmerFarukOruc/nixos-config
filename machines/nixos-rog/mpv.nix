{
  config,
  lib,
  pkgs,
  ...
}:
let
  modernzColors =
    { scheme, ... }:
    let
      color = scheme.withHashtag;
    in
    lib.generators.toKeyValue { } {
      osc_color = color.base00;
      window_title_color = color.base05;
      window_controls_color = color.base05;
      windowcontrols_close_hover = color.base08;
      windowcontrols_max_hover = color.base0A;
      windowcontrols_min_hover = color.base0B;
      title_color = color.base05;
      cache_info_color = color.base05;
      seekbar_cache_color = color.base03;
      seekbarfg_color = color.base0D;
      seekbarbg_color = color.base02;
      seek_handle_color = color.base0D;
      seek_handle_border_color = color.base05;
      time_color = color.base05;
      chapter_title_color = color.base05;
      side_buttons_color = color.base05;
      middle_buttons_color = color.base05;
      playpause_color = color.base05;
      held_element_color = color.base03;
      hover_effect_color = color.base0D;
      thumbnail_box_color = color.base01;
      thumbnail_box_outline = color.base03;
      nibble_color = color.base0D;
      nibble_current_color = color.base05;
      ab_loop_color = color.base0C;
    };
  osdColors =
    { scheme, ... }:
    lib.generators.toKeyValue { } {
      osd-color = scheme.withHashtag.base05;
      osd-border-color = scheme.withHashtag.base00;
    };

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
      include = "~/.config/mpv/oruc-colors.conf";
    };
  };

  oruc.themeFiles = {
    ".config/mpv/script-opts/modernz.conf" = modernzColors;
    ".config/mpv/oruc-colors.conf" = osdColors;
  };

  home.packages = [
    (pkgs.writeShellScriptBin "mpv-nvidia" ''
      VK_LOADER_DRIVERS_SELECT='*nvidia*' exec nvidia-offload ${lib.getExe config.programs.mpv.finalPackage} --hwdec=auto-copy "$@"
    '')
  ];

  xdg.mimeApps.defaultApplications = lib.genAttrs mimeTypes (_: [ "mpv.desktop" ]);
}
