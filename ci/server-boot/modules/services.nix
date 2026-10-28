# What the services checks (../checks/20-services.py) need around the host:
# local backends for the web names and the image that the container checks
# start. No certificate authority answers here, so the web names serve the
# self-signed certificates that security.acme makes before it asks.
{
  lib,
  pkgs,
  ...
}:
let
  # A one-layer image of busybox, so the container checks need no registry.
  probeImage = pkgs.dockerTools.buildImage {
    name = "probe";
    tag = "1";
    copyToRoot = pkgs.buildEnv {
      name = "probe-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
  };

  # A web server that answers with the headers it received, for the local
  # ports that Caddy proxies to.
  echoServer = pkgs.writeText "echo-server.py" ''
    import sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            lines = [f"x-backend-port: {sys.argv[1]}"]
            lines += [f"{k}: {v}" for k, v in self.headers.items()]
            body = ("\n".join(lines) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass


    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
  '';
in
{
  security.acme.defaults.server = "https://127.0.0.1:1/dir";

  environment.etc."server-boot/probe-image.tar".source = probeImage;

  # The checks call these from a root shell.
  environment.systemPackages = [
    pkgs.curl
    pkgs.openssl
  ];

  systemd.services = lib.listToAttrs (
    map
      (
        port:
        lib.nameValuePair "server-boot-echo-${toString port}" {
          description = "Test only: a backend on port ${toString port}";
          wantedBy = [ "multi-user.target" ];
          before = [ "caddy.service" ];
          serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${echoServer} ${toString port}";
        }
      )
      [
        3000
        7317
        7318
      ]
  );

  # The echo backends above own ports 3000 and 7317, so oruc's OpenChamber and
  # herdr web UI stay off. The Amp runner, the Cursor worker and stay-green
  # need Omer's logins, cliproxy needs a registry and claude-limit-switch starts
  # herdr's session; the test has none of them.
  home-manager.users.oruc.systemd.user = {
    services =
      lib.genAttrs
        [
          "amp-runner"
          "cliproxy"
          "cursor-worker"
          "herdr-web-ui"
          "openchamber"
        ]
        (_: {
          Install.WantedBy = lib.mkForce [ ];
        });
    timers =
      lib.genAttrs
        [
          "claude-limit-switch"
          "cliproxy-update"
          "stay-green"
        ]
        (_: {
          Install.WantedBy = lib.mkForce [ ];
        });
  };
}
