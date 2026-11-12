{ config, ... }:
let
  secrets = ../../secrets/devbox-services.yaml;
  cliproxy = ../../secrets/devbox-cliproxy.yaml;
  threadsift = ../../secrets/devbox-threadsift.yaml;
  inherit (config.sops) placeholder;
  user = config.oruc.machine.user;
  userSecret = {
    sopsFile = secrets;
    owner = user;
  };
  cliproxySecret = key: {
    sopsFile = cliproxy;
    inherit key;
    owner = user;
  };
  threadsiftSecret = key: {
    sopsFile = threadsift;
    inherit key;
    owner = user;
  };
in
{
  sops = {
    secrets = {
      openchamber-ui-password.sopsFile = secrets;
      opencode-server-password.sopsFile = secrets;
      herdr-web-token = userSecret;
      cliproxy-api-key-omer = cliproxySecret "api-key-omer";
      cliproxy-api-key-friend = cliproxySecret "api-key-friend";
      cliproxy-management-key = cliproxySecret "management-key";
      cliproxy-cloudflare-dns-token = cliproxySecret "cloudflare-dns-token";
      cliproxy-ts-authkey = cliproxySecret "ts-authkey";
      cliproxy-share-host = cliproxySecret "share-host";
      threadsift-connector-token = threadsiftSecret "connector-token";
      threadsift-secret-key = threadsiftSecret "secret-key";
      threadsift-setup-code = threadsiftSecret "setup-code";
      threadsift-claude-code-oauth-token = threadsiftSecret "claude-code-oauth-token";
      infisical-client-id = userSecret;
      infisical-client-secret = userSecret;
      infisical-project-id = userSecret;
    };
    templates."infisical-agent.yaml" = {
      owner = user;
      content = builtins.toJSON {
        infisical.address = "https://eu.infisical.com";
        auth = {
          type = "universal-auth";
          config = {
            client-id = config.sops.secrets.infisical-client-id.path;
            client-secret = config.sops.secrets.infisical-client-secret.path;
            remove_client_secret_on_read = false;
          };
        };
        sinks = [
          {
            type = "file";
            config.path = "token";
          }
        ];
        templates = [
          {
            template-content = ''
              {{- with listSecrets "${placeholder.infisical-project-id}" "secrets" "/harness/openrouter-guardrail" }}{{ range . }}
              {{ .Key }}={{ .Value }}
              {{- end }}{{ end }}
            '';
            destination-path = "openrouter-guardrail.env";
          }
        ];
      };
    };
    templates."cliproxy-config.yaml" = {
      owner = user;
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
      owner = user;
      content = ''
        CLIPROXY_SHARE_HOST=${placeholder.cliproxy-share-host}
        CLIPROXY_TS_AUTHKEY=${placeholder.cliproxy-ts-authkey}
      '';
    };
    templates."threadsift.env" = {
      owner = user;
      content = ''
        TUNNEL_TOKEN=${placeholder.threadsift-connector-token}
        THREADSIFT_SECRET_KEY=${placeholder.threadsift-secret-key}
        SETUP_CODE=${placeholder.threadsift-setup-code}
        CLAUDE_CODE_OAUTH_TOKEN=${placeholder.threadsift-claude-code-oauth-token}
      '';
    };
    templates."openchamber.env" = {
      owner = user;
      content = ''
        OPENCHAMBER_UI_PASSWORD=${placeholder.openchamber-ui-password}
        OPENCODE_SERVER_PASSWORD=${placeholder.opencode-server-password}
      '';
    };
  };
}
