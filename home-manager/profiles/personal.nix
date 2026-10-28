# Omer's own apps and dev tools, on top of the workstation profile, for the
# machines he works at every day. The GPU tools follow the machine record.
{
  agents,
  inputs,
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
  imports = [
    ../modules/agent-cli.nix
    ../modules/playwright.nix
  ];

  # ChatGPT and Grok Bot register their URL schemes with xdg-mime at start;
  # declaring them keeps that rewrite of mimeapps.list identical to the Home
  # Manager file. Thunderbird opens mailto links.
  xdg.mimeApps.defaultApplications = {
    "x-scheme-handler/codex" = [ "chatgpt.desktop" ];
    "x-scheme-handler/grokbot" = [ "grok-bot.desktop" ];
    "x-scheme-handler/sand" = [ "grok-bot.desktop" ];
    "x-scheme-handler/mailto" = [ "thunderbird.desktop" ];
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
      fastfetch
      frida-tools
      gum
      hwinfo
      iptvnator
      jadx
      kdePackages.kate
      lmstudio
      nvtop
      obsidian
      openssl
      pandoc
      podman-desktop
      qbittorrent
      silicon
      slack
      thunderbird
      tigervnc
      vhs
      vlc
    ]
    ++ [
      (pkgs.callPackage ../../pkgs/antigravity-hub.nix { })
      (pkgs.callPackage ../../pkgs/chatgpt.nix { })
      (pkgs.callPackage ../../pkgs/grok-bot.nix { })
      # The Linear CLI agents run from a repository with a .linctl.toml pin.
      (pkgs.callPackage ../../pkgs/linctl.nix { })
      (pkgs.callPackage ../../pkgs/openchamber.nix { })
      # `stay-green login risoluto-dev-1` signs in here, in the browser, and
      # stores the sign-in on the box, where stay-green.timer runs.
      (pkgs.callPackage ../../pkgs/stay-green.nix { src = inputs.stay-green; })
    ]
    ++ [ agents.antigravity-cli ];
}
