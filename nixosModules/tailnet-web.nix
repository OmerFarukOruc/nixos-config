# Web names for the tailnet. Each name has a public, DNS-only A record to the
# host's tailnet address, so it resolves everywhere and connects only from the
# tailnet: Caddy listens on every address, and the firewall (tailscale.nix)
# opens no port on the public interface and trusts tailscale0 only. Caddy
# terminates TLS with a certificate per name from security.acme (Let's Encrypt,
# DNS-01 challenge at Cloudflare) and proxies the name to a local port.
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
        # The host's resolvers can keep answering NXDOMAIN for the challenge
        # record until lego's time limit, and Let's Encrypt does not use them.
        # lego still waits for the zone's own name servers, which
        # dnsPropagationCheck = false would skip as well.
        extraLegoFlags = [ "--dns.propagation.disable-rns" ];
      };
      certs = lib.mapAttrs (_: _: { }) cfg.sites;
    };

    services.caddy = {
      enable = true;
      # The admin API is off, so Caddy cannot reload; a change restarts it.
      enableReload = false;
      globalConfig = ''
        auto_https off
        admin off
        # Open event streams would otherwise hold a restart until systemd's
        # stop timeout. 10 s is the Debian box's value.
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
  };
}
