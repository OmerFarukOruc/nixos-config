# Omer's own apps and dev tools, on top of the workstation profile, for the
# machines he works at every day. The GPU tools follow the machine record.
{
  agents,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.oruc.machine) gpu;
  # hybrid is a Radeon with an NVIDIA card, as on nixos-rog.
  hasAmd = gpu == "amd" || gpu == "hybrid";
  hasNvidia = gpu == "nvidia" || gpu == "hybrid";
  nvtop =
    {
      amd = pkgs.nvtopPackages.amd;
      intel = pkgs.nvtopPackages.intel;
      nvidia = pkgs.nvtopPackages.nvidia;
    }
    .${gpu} or pkgs.nvtopPackages.full;
in
{
  # Both apps register their URL schemes with xdg-mime at start; declaring them
  # keeps that rewrite of mimeapps.list identical to the Home Manager file.
  xdg.mimeApps.defaultApplications = {
    "x-scheme-handler/codex" = [ "chatgpt.desktop" ];
    "x-scheme-handler/grokbot" = [ "grok-bot.desktop" ];
    "x-scheme-handler/sand" = [ "grok-bot.desktop" ];
  };

  home.sessionVariables = {
    # Playwright uses the nixpkgs browsers; npm's downloaded ones do not run here.
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };

  home.packages =
    with pkgs;
    lib.optional hasAmd amdgpu_top
    ++ [
      android-tools
      apkeep
      chromium
      code-cursor
    ]
    ++ lib.optional hasNvidia cudaPackages.cudatoolkit
    ++ [
      devenv
      fastfetch
      frida-tools
      gum
      hwinfo
      iptvnator
      jadx
      kdePackages.kate
      lmstudio
      mitmproxy
      nvtop
      obsidian
      openssl
      pandoc
      podman-desktop
      qbittorrent
      silicon
      slack
      tigervnc
      vhs
      vlc
    ]
    ++ [
      (pkgs.callPackage ../../pkgs/antigravity-hub.nix { })
      (pkgs.callPackage ../../pkgs/chatgpt.nix { })
      (pkgs.callPackage ../../pkgs/grok-bot.nix { })
      (pkgs.callPackage ../../pkgs/openchamber.nix { })
    ]
    ++ (with agents; [
      agent-browser
      antigravity-cli
      pi
    ]);
}
