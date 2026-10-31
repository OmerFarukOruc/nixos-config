_: {
  xdg.desktopEntries.iptvnator = {
    name = "IPTVnator";
    comment = "IPTV player, through devbox";
    exec = "via-devbox iptvnator --disable-features=UseDnsHttpsSvcb %U";
    icon = "iptvnator";
    categories = [
      "AudioVideo"
      "Video"
    ];
    settings.StartupWMClass = "iptvnator";
  };
}
