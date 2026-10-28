{
  config,
  lib,
  ...
}:
let
  cfg = config.oruc.tailnetWeb;
in
{
  options.oruc.tailnetWeb = {
    dnsTokenFile = lib.mkOption {
      type = lib.types.path;
      description = "File that holds the Cloudflare API token for the DNS-01 challenge. It needs Zone Read and DNS Edit on the zone of the names, because lego looks the zone up.";
    };
    sites = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "app.example.com" = "127.0.0.1:3000";
      };
      description = "Web names to serve, each with the address that Caddy proxies it to. No site means no Caddy and no certificate. Caddy removes the Tailscale-User-Login header from every request, because a client could forge it and an app can take it for the identity that tailscale serve sets.";
    };
  };

  config = lib.mkIf (cfg.sites != { }) {
    security.acme = {
      acceptTerms = true;
      defaults = {
        dnsProvider = "cloudflare";
        credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE = cfg.dnsTokenFile;
        extraLegoFlags = [ "--dns.propagation.disable-rns" ];
      };
      certs = lib.mapAttrs (_: _: { }) cfg.sites;
    };

    services.caddy = {
      enable = true;
      enableReload = false;
      globalConfig = ''
        auto_https off
        admin off
        grace_period 10s
      '';
      virtualHosts = lib.mapAttrs' (
        name: upstream:
        lib.nameValuePair "https://${name}" {
          useACMEHost = name;
          extraConfig = ''
            reverse_proxy ${upstream} {
              header_up -Tailscale-User-Login
              flush_interval -1
            }
          '';
        }
      ) cfg.sites;
    };

    # Every order that installs a new certificate restarts Caddy (reloadServices
    # of the module), and the orders after the first run at the same time. An
    # order that has copied its files but not yet run its chmod leaves a
    # certificate and key that Caddy cannot read. Caddy then exits with status 1,
    # which its unit never restarts. A restart stops Caddy at once, and its start
    # waits for the orders that run, so Caddy starts only once they are done.
    systemd.services.caddy.after = lib.mapAttrsToList (
      name: _: "acme-order-renew-${name}.service"
    ) cfg.sites;
  };
}
