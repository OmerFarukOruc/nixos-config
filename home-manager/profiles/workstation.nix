{
  agents,
  config,
  lib,
  pkgs,
  ...
}:
let
  # https://gitlab.com/Remmina/Remmina/-/blob/v1.4.43/src/include/remmina/types.h#L146
  remminaDynamicResolution = 2;
  remminaSettings = {
    # xrdp gives the session the keyboard layout that the client sends, and
    # Remmina sends the one of this preference. At its default (0) FreeRDP
    # guesses: from the layout names on the X root window, which a Wayland
    # session may not set, and then from the locale, en_US here
    # (nixosModules/common.nix), so the session may get us instead of the
    # Turkish Q layout (0x041F) of these machines.
    "${config.xdg.configHome}/remmina/remmina.pref".remmina_pref.rdp_keyboard_layout = "41F";
    # Remmina's profile editor deletes the file on save and writes it again
    # under the name its remmina_file_name pattern gives, %G_%P_%N_%h, so
    # the file already has that name.
    "${config.xdg.dataHome}/remmina/group_rdp_devbox_devbox.remmina".remmina = {
      name = "devbox";
      protocol = "RDP";
      server = "devbox";
      username = "omer";
      scale = remminaDynamicResolution;
      drive = config.home.homeDirectory;
      sound = "local";
    };
  };
  # GTK3 on Wayland draws at whole-number scales only, so on a fractional
  # Plasma scale KWin resamples Remmina and every remote pixel lands on a
  # fraction of a screen pixel. Plasma's Xwayland lets X11 apps scale
  # themselves and publishes the scale as Xft.dpi. GTK3 on X11 with
  # GDK_SCALE set takes its font DPI from Xft.dpi, which already holds the
  # scale, so GDK_DPI_SCALE divides it back out.
  remminaScaleEnv = pkgs.writeShellScript "remmina-scale-env" ''
    [ -z "''${GDK_BACKEND-}" ] && [ "''${XDG_CURRENT_DESKTOP-}" = KDE ] || exit 0
    dpi=$(${lib.getExe pkgs.xrdb} -get Xft.dpi 2>/dev/null) || exit 0
    ${lib.getExe pkgs.gawk} -v dpi="$dpi" 'BEGIN {
      if (dpi + 0 <= 0) exit
      scale = int(dpi / 96 + 0.5)
      if (scale < 1) scale = 1
      printf "export GDK_BACKEND=x11 GDK_SCALE=%d GDK_DPI_SCALE=%g\n", scale, 1 / scale
    }'
  '';
  remminaWholePixelScale = pkgs.symlinkJoin {
    inherit (pkgs.remmina) name meta;
    paths = [ pkgs.remmina ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for bin in remmina remmina-file-wrapper; do
        rm $out/bin/$bin
        makeWrapper ${pkgs.remmina}/bin/$bin $out/bin/$bin --run 'eval "$(${remminaScaleEnv})"'
      done
      for desktop in $out/share/applications/*.desktop; do
        rm "$desktop"
        sed 's|${pkgs.remmina}/bin/|'"$out"'/bin/|g' \
          "${pkgs.remmina}/share/applications/$(basename "$desktop")" >"$desktop"
        if grep -q '${pkgs.remmina}/bin/' "$desktop"; then exit 1; fi
      done
    '';
  };
in
{
  imports = [
    ../modules/airpods.nix
    ../modules/spicetify.nix
  ];

  xdg.mimeApps.defaultApplications = {
    "inode/directory" = [ "org.kde.dolphin.desktop" ];
  }
  // lib.genAttrs [
    "application/gzip"
    "application/vnd.rar"
    "application/x-7z-compressed"
    "application/x-bzip2"
    "application/x-bzip2-compressed-tar"
    "application/x-compressed-tar"
    "application/x-rar"
    "application/x-tar"
    "application/x-xz"
    "application/x-xz-compressed-tar"
    "application/x-zstd-compressed-tar"
    "application/zip"
    "application/zstd"
  ] (_: [ "org.kde.ark.desktop" ]);

  # Mission Center opens its "Enabling Additional Values" setup dialog on the
  # first launch without checking anything. nixosModules/mission-center.nix
  # already grants what its setup script would, and the script cannot write
  # NixOS's udev rules, so the dialog never opens.
  dconf.settings."io/missioncenter/MissionCenter".first-time-running = false;

  services.remmina = {
    enable = true;
    package = remminaWholePixelScale;
    systemdService.enable = false;
  };
  # Remmina writes window sizes and view modes back into these files, so the
  # activation merges the keys below into them instead of linking store files.
  home.activation.remmina = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    lib.concatStrings (
      lib.mapAttrsToList (file: settings: ''
        run install -d -m 0750 ${lib.escapeShellArg (dirOf file)}
        run ${lib.getExe pkgs.crudini} --ini-options=nospace --merge ${lib.escapeShellArg file} \
          < ${pkgs.writeText (baseNameOf file) (lib.generators.toINI { } settings)}
      '') remminaSettings
    )
  );

  home.packages =
    with pkgs;
    [
      # keep-sorted start
      deskflow
      devenv
      discord
      kdePackages.ark
      kdePackages.dolphin
      kdePackages.kio-extras
      mission-center
      moonlight-qt
      telegram-desktop
      wl-clipboard
      # keep-sorted end
    ]
    ++ [
      # The .deb's desktop file also opens MCP bundles and skill files.
      (pkgs.symlinkJoin {
        inherit (agents.claude-desktop) name meta;
        paths = [ agents.claude-desktop ];
        postBuild = ''
          desktop=$out/share/applications/com.anthropic.Claude.desktop
          rm $out/share
          cp -rs --no-preserve=mode "$(readlink -f ${agents.claude-desktop}/share)" $out/share
          rm "$desktop"
          sed 's|^MimeType=.*|MimeType=x-scheme-handler/claude;application/vnd.anthropic.mcpb;application/vnd.anthropic.skill;|' \
            ${agents.claude-desktop}/share/applications/com.anthropic.Claude.desktop >"$desktop"
          grep -qx 'MimeType=x-scheme-handler/claude;application/vnd.anthropic.mcpb;application/vnd.anthropic.skill;' "$desktop"
        '';
      })
    ];
}
