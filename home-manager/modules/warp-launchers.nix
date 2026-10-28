{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  proxy = osConfig.oruc.warpProxy;
  braveDir = "${config.xdg.configHome}/BraveSoftware/Brave-WARP";
  # Brave ignores --force-webrtc-ip-handling-policy, so the profile's own
  # preference keeps WebRTC from sending UDP around the proxy. Brave
  # rewrites Preferences while it runs, so the script sets it only when Brave is
  # not running.
  brave-warp = pkgs.writeShellApplication {
    name = "brave-warp";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      prefs="${braveDir}/Default/Preferences"
      if [[ ! -L "${braveDir}/SingletonLock" ]]; then
        mkdir -p "$(dirname "$prefs")"
        [[ -s $prefs ]] || echo '{}' >"$prefs"
        jq '.webrtc.ip_handling_policy = "disable_non_proxied_udp"' "$prefs" >"$prefs.new"
        mv "$prefs.new" "$prefs"
      fi
      exec brave-origin --user-data-dir="${braveDir}" --proxy-server=${proxy} "$@"
    '';
  };
in
{
  xdg.desktopEntries = {
    discord-warp = {
      name = "Discord (WARP)";
      exec = "discord --proxy-server=${proxy}";
      icon = "discord";
      categories = [
        "Network"
        "InstantMessaging"
      ];
    };
    brave-warp = {
      name = "Brave (WARP)";
      exec = "${lib.getExe brave-warp} %U";
      icon = "brave-origin";
      categories = [
        "Network"
        "WebBrowser"
      ];
    };
  };
}
