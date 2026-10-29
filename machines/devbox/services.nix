{ config, ... }:
let
  secrets = ../../secrets/devbox-services.yaml;
  cliproxy = ../../secrets/devbox-cliproxy.yaml;
  inherit (config.sops) placeholder;
  cliproxySecret = key: {
    sopsFile = cliproxy;
    inherit key;
    owner = config.oruc.machine.user;
  };
in
{
  sops = {
    secrets = {
      openchamber-ui-password.sopsFile = secrets;
      opencode-server-password.sopsFile = secrets;
      herdr-web-token = {
        sopsFile = secrets;
        owner = config.oruc.machine.user;
      };
      cliproxy-api-key-omer = cliproxySecret "api-key-omer";
      cliproxy-api-key-friend = cliproxySecret "api-key-friend";
      cliproxy-management-key = cliproxySecret "management-key";
      cliproxy-cloudflare-dns-token = cliproxySecret "cloudflare-dns-token";
      cliproxy-ts-authkey = cliproxySecret "ts-authkey";
      cliproxy-share-host = cliproxySecret "share-host";
    };
    templates."cliproxy-config.yaml" = {
      owner = config.oruc.machine.user;
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
    templates."cliproxy.env" = {
      owner = config.oruc.machine.user;
      content = ''
        CLIPROXY_SHARE_HOST=${placeholder.cliproxy-share-host}
        CLIPROXY_TS_AUTHKEY=${placeholder.cliproxy-ts-authkey}
      '';
    };
    templates."openchamber.env" = {
      owner = config.oruc.machine.user;
      content = ''
        OPENCHAMBER_UI_PASSWORD=${placeholder.openchamber-ui-password}
        OPENCODE_SERVER_PASSWORD=${placeholder.opencode-server-password}
      '';
    };
  };
}
