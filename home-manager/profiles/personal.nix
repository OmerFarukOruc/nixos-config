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
      (pkgs.callPackage ../../pkgs/grok-bot.nix { })
      (pkgs.callPackage ../../pkgs/linctl.nix { })
      (pkgs.callPackage ../../pkgs/openchamber.nix { })
      (pkgs.callPackage ../../pkgs/stay-green.nix { src = inputs.stay-green; })
    ]
    ++ [
      agents.antigravity-cli
      # Only its own codex:// links: the .deb also claims web links and office files.
      (pkgs.symlinkJoin {
        inherit (agents.chatgpt) name meta;
        paths = [ agents.chatgpt ];
        postBuild = ''
          desktop=$out/share/applications/chatgpt.desktop
          rm $out/share
          cp -rs --no-preserve=mode "$(readlink -f ${agents.chatgpt}/share)" $out/share
          rm "$desktop"
          sed 's|^MimeType=.*|MimeType=x-scheme-handler/codex;|' \
            ${agents.chatgpt}/share/applications/chatgpt.desktop >"$desktop"
          grep -qx 'MimeType=x-scheme-handler/codex;' "$desktop"
        '';
      })
    ];
}
