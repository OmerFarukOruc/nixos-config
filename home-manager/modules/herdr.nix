{
  agents,
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  herdr = lib.getExe agents.herdr;
  hasDesktop = sessions.hasAnyDesktop osConfig.oruc.machine;
  sessionTarget = if hasDesktop then "graphical-session.target" else "default.target";
  configFile = "${config.xdg.configHome}/herdr/config.toml";
  settings = {
    onboarding = false;
    theme.name = "terminal";
    ui.toast.delivery = "system";
    ui.agent_panel_sort = "spaces";
    update.version_check = false;
    session.resume_agents_on_restore = !(config.systemd.user.services ? claude-tools-limit-switch);
  };
  setSettings = pkgs.writers.writePython3 "herdr-set-settings" {
    libraries = [ pkgs.python3Packages.tomlkit ];
  } (builtins.readFile ./herdr-settings.py);
  integrations = {
    antigravity-cli = ".gemini/config";
    claude = ".claude";
    codex = ".codex";
    cursor = ".cursor";
    grok = ".grok";
    opencode = ".config/opencode";
    pi = ".pi/agent";
  };
in
{
  systemd.user.services.herdr-default = {
    Unit = {
      Description = "herdr default session, where Omer's own agents run";
      After = lib.optional hasDesktop "graphical-session.target";
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Slice = "session.slice";
      ManagedOOMPreference = "avoid";
      UMask = "0022";
      Environment = [ "SHELL=${lib.getExe pkgs.zsh}" ];
      WorkingDirectory = config.home.homeDirectory;
      ExecCondition = "${pkgs.bash}/bin/bash -c '! ${herdr} status server 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qx \"status: running\"'";
      ExecStart = "${lib.getExe pkgs.zsh} -c 'exec herdr server'";
      Restart = "always";
      RestartSec = 5;
    }
    // lib.optionalAttrs hasDesktop {
      MemoryMax = "20G";
      MemorySwapMax = "6G";
      TasksMax = 4096;
    };
    Install.WantedBy = [ sessionTarget ];
  };

  home.activation.herdrSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${setSettings} ${lib.escapeShellArg configFile} \
      ${pkgs.writeText "herdr-settings.json" (builtins.toJSON settings)} ${herdr} \
      || warnEcho "herdr's config.toml is unchanged; the declared settings apply at the next switch after it parses."
  '';

  # herdr reports an integration that an older herdr installed as outdated but
  # does not update it, so each switch installs the ones that are not current.
  home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    herdrStatus=$'\n'"$(${herdr} integration status 2>/dev/null || true)"
    ${lib.concatStrings (
      lib.mapAttrsToList (id: dir: ''
        if [[ -d "$HOME/${dir}" && $herdrStatus != *$'\n'"${id}: current "* ]]; then
          run ${herdr} integration install ${id} \
            || warnEcho "herdr could not install its ${id} integration."
        fi
      '') integrations
    )}
    unset herdrStatus
  '';
}
