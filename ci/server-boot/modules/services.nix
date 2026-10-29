{
  config,
  lib,
  pkgs,
  ...
}:
let
  probeImage = pkgs.dockerTools.buildImage {
    name = "probe";
    tag = "1";
    copyToRoot = pkgs.buildEnv {
      name = "probe-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
  };

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

  home-manager.users.${config.oruc.machine.user}.systemd.user = {
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
