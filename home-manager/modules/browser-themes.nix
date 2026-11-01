{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  pywalfoxId = "pywalfox@frewacom.org";
  pywalfoxStart = pkgs.writeShellScript "pywalfox-start" ''
    exec ${lib.getExe' pkgs.pywalfox-native "pywalfox"} start
  '';
  pywalfoxHost = pkgs.writeTextDir "lib/mozilla/native-messaging-hosts/pywalfox.json" (
    builtins.toJSON {
      name = "pywalfox";
      description = "Pywalfox native host";
      path = "${pywalfoxStart}";
      type = "stdio";
      allowed_extensions = [ pywalfoxId ];
    }
  );
  firefox = pkgs.firefox.override {
    nativeMessagingHosts = [ pywalfoxHost ];
    extraPolicies.ExtensionSettings.${pywalfoxId} = {
      installation_mode = "force_installed";
      install_url = "https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi";
    };
  };
  pywalfox = pkgs.writeShellApplication {
    name = "oruc-pywalfox";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.pywalfox-native
      config.oruc.wallpaper
    ];
    text = ''
      facts=${lib.escapeShellArg config.oruc.themeFactsDir}
      wal=''${XDG_CACHE_HOME:-$HOME/.cache}/wal
      mkdir -p "$wal"
      jq -n --slurpfile colors "$facts/pywal-colors" --arg wallpaper "$(oruc-wallpaper-path)" '
        { wallpaper: $wallpaper,
          colors: ($colors[0] | to_entries | map({ key: "color\(.key)", value }) | from_entries) }
      ' >"$wal/colors.json.oruc-tmp"
      mv -T "$wal/colors.json.oruc-tmp" "$wal/colors.json"
      pywalfox "$(<"$facts/polarity")" >/dev/null
      pywalfox update
    '';
  };
  gtkMode.extensions.theme.system_theme = 1;
  chromiumPreferences = dir: {
    path = "${config.xdg.configHome}/${dir}/Default/Preferences";
    format = "json";
    values = gtkMode;
    create = false;
  };
in
{
  options.oruc.firefox = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = firefox;
    description = "Firefox with the Pywalfox add-on and its native host, which take the stored scheme's 16 colours.";
  };

  config = lib.mkIf (sessions.hasGraphicalUser osConfig.oruc.machine) {
    oruc.themeFacts.pywal-colors =
      { scheme, theme }: builtins.toJSON (map (slot: "#${scheme.${slot}}") theme.ansi);
    oruc.variantReloads.pywalfox = lib.getExe pywalfox;

    oruc.appSettings = {
      brave = {
        label = "Brave";
        executables = [
          {
            package = "brave-origin";
            path = "opt/brave.com/brave-origin/brave";
          }
        ];
        files = map chromiumPreferences [
          "BraveSoftware/Brave-Origin"
          "BraveSoftware/Brave-WARP"
        ];
      };
      chromium = {
        label = "Chromium";
        executables = [
          {
            package = "chromium-unwrapped";
            path = "libexec/chromium/chromium";
          }
        ];
        files = [ (chromiumPreferences "chromium") ];
      };
    };
  };
}
