# The secrets of Omer's own user services on the box (home.nix), from
# secrets/risoluto-dev-1-services.yaml and, for CLIProxyAPI,
# secrets/risoluto-dev-1-cliproxy.yaml. oruc owns the rendered files, because
# the services run in oruc's user manager. sops-nix restarts only system
# units, so restart the user service after its secret changes.
{ config, ... }:
let
  secrets = ../../secrets/risoluto-dev-1-services.yaml;
  cliproxy = ../../secrets/risoluto-dev-1-cliproxy.yaml;
  inherit (config.sops) placeholder;
  # A cliproxy secret, named after its key in the file, read only by oruc's
  # cliproxy.service.
  cliproxySecret = key: {
    sopsFile = cliproxy;
    inherit key;
    owner = "oruc";
  };
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
      cliproxy-api-key-omer = cliproxySecret "api-key-omer";
      cliproxy-api-key-friend = cliproxySecret "api-key-friend";
      cliproxy-management-key = cliproxySecret "management-key";
      cliproxy-cloudflare-dns-token = cliproxySecret "cloudflare-dns-token";
      cliproxy-ts-authkey = cliproxySecret "ts-authkey";
      cliproxy-share-host = cliproxySecret "share-host";
    };
    # The app's config; cliproxy-up.sh gives the app a writable copy.
    templates."cliproxy-config.yaml" = {
      owner = "oruc";
      content = builtins.toJSON {
        host = "";
        port = 8317;
        auth-dir = "/root/.cli-proxy-api";
        api-keys = [
          placeholder.cliproxy-api-key-omer
          placeholder.cliproxy-api-key-friend
        ];
        debug = false;
        logging-to-file = false;
        ws-auth = true;
        request-retry = 3;
        routing.strategy = "round-robin";
        remote-management = {
          allow-remote = true;
          secret-key = placeholder.cliproxy-management-key;
          disable-control-panel = false;
        };
      };
    };
    # The share node's ts.net name is the tailnet name, which this public
    # repository keeps out of git.
    templates."cliproxy.env" = {
      owner = "oruc";
      content = ''
        CLIPROXY_SHARE_HOST=${placeholder.cliproxy-share-host}
        CLIPROXY_TS_AUTHKEY=${placeholder.cliproxy-ts-authkey}
      '';
    };
    templates."openchamber.env" = {
      owner = "oruc";
      content = ''
        OPENCHAMBER_UI_PASSWORD=${placeholder.openchamber-ui-password}
        OPENCODE_SERVER_PASSWORD=${placeholder.opencode-server-password}
      '';
    };
  };
}
