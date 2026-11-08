{
  agents,
  config,
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
    ./workstation.nix
    ../modules/desktop-sync.nix
    ../modules/heavy.nix
    ../modules/box-view.nix
    ../modules/sshfs-devbox.nix
    ../modules/via-devbox-launchers.nix
    ../modules/warp-launchers.nix
    ../modules/deskflow.nix
    ../modules/agent-cli.nix
    ../modules/app-themes.nix
    ../modules/gaming.nix
    ../modules/playwright.nix
  ];

  oruc.plasma.dockLaunchers = [
    "preferred://filemanager"
    "applications:io.missioncenter.MissionCenter.desktop"
    "preferred://browser"
    "applications:com.mitchellh.ghostty.desktop"
    "applications:SourceGit.desktop"
    "applications:code.desktop"
    "applications:chatgpt.desktop"
    "applications:com.anthropic.Claude.desktop"
    "applications:grok-bot.desktop"
    "applications:openchamber.desktop"
    "applications:cursor.desktop"
    "applications:slack.desktop"
    "applications:brave-ompifgpmddkgmclendfeacglnodjjndh-Default.desktop"
    "applications:brave-hnpfjngllnobngcgfapefoaidbinmjnm-Default.desktop"
    "applications:vesktop.desktop"
    "applications:org.telegram.desktop.desktop"
    "applications:spotify.desktop"
    "applications:md.obsidian.Obsidian.desktop"
  ];

  oruc.cursorEditor = true;

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
      (pkgs.callPackage ../../pkgs/openchamber.nix { })
      (pkgs.callPackage ../../pkgs/oracle.nix { })
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

  home.file.".oracle/config.json" = {
    text = builtins.toJSON {
      engine = "browser";
      model = "gpt-6-pro";
      browser = {
        manualLogin = true;
        chromePath = "${config.home.profileDirectory}/bin/brave-origin";
        noFocus = true;
        timeoutMs = 3600000;
      };
    };
    force = true;
  };
}
