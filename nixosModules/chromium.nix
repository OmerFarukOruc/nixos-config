{
  config,
  lib,
  ...
}:
let
  cfg = config.oruc.machine;
in
lib.mkIf (cfg.kind == "workstation") {
  # Chromium hands every mailto: link to the desktop portal without a prompt,
  # headless too, so an agent-browser click opens Thunderbird on the screen.
  # programs.chromium.extraOpts would also write Brave's policies, and Brave
  # must keep opening mailto: links.
  environment.etc."chromium/policies/managed/oruc.json".text = builtins.toJSON {
    URLBlocklist = [ "mailto:*" ];
  };
}
