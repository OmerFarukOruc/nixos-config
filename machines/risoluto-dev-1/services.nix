# The secrets of Omer's own user services on the box (home.nix), from
# secrets/risoluto-dev-1-services.yaml. oruc owns the rendered files, because
# the services run in oruc's user manager. sops-nix restarts only system
# units, so restart the user service after its secret changes.
{ config, ... }:
let
  secrets = ../../secrets/risoluto-dev-1-services.yaml;
in
{
  sops = {
    secrets = {
      openchamber-ui-password.sopsFile = secrets;
      opencode-server-password.sopsFile = secrets;
      herdr-web-token = {
        sopsFile = secrets;
        owner = "oruc";
      };
    };
    templates."openchamber.env" = {
      owner = "oruc";
      content = ''
        OPENCHAMBER_UI_PASSWORD=${config.sops.placeholder.openchamber-ui-password}
        OPENCODE_SERVER_PASSWORD=${config.sops.placeholder.opencode-server-password}
      '';
    };
  };
}
