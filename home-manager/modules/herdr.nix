{
  agents,
  config,
  lib,
  pkgs,
  ...
}:
let
  herdr = lib.getExe agents.herdr;
  configFile = "${config.xdg.configHome}/herdr/config.toml";
  # herdr's Settings menu and first-run setup write config.toml, so it stays a
  # writable file. Each switch sets these keys and leaves the others to herdr.
  settings = {
    onboarding = false;
    # The terminal's 16 ANSI colors, which come from the scheme.
    theme.name = "terminal";
    ui.toast.delivery = "system";
    # Nix delivers new versions; herdr update cannot replace a store path.
    update.version_check = false;
  };
  setSettings = pkgs.writers.writePython3 "herdr-set-settings" {
    libraries = [ pkgs.python3Packages.tomlkit ];
  } (builtins.readFile ./herdr-settings.py);
  # Each agent's config directory below $HOME, which herdr's install needs.
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
