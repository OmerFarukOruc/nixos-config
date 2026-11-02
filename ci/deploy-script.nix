{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  user = "deployer";
  host = "deploy-target";
  sleeper = {
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      Restart = "on-failure";
      RestartSec = 300;
    };
  };
in
{
  deploy-script = pkgs.testers.runNixOSTest {
    name = "deploy-script";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ ../nixosModules/deploy-host.nix ];

        networking.hostName = host;
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
        virtualisation = {
          memorySize = 2048;
          emptyDiskImages = [ 4096 ];
          fileSystems."/boot" = {
            device = "/dev/vdb";
            fsType = "vfat";
            autoFormat = true;
          };
        };
        boot.loader = {
          efi.canTouchEfiVariables = false;
          limine = {
            enable = true;
            efiSupport = true;
            efiInstallAsRemovable = true;
          };
        };
        environment.systemPackages = [
          pkgs.git
          pkgs.rsync
        ];
        services.openssh.enable = true;
        services.tailscale.enable = true;
        security.sudo.wheelNeedsPassword = false;

        users.users.${user} = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          linger = true;
        };
        oruc.deploy.sessionIgnore = [ "ignored-*.service" ];
        systemd.user.services = {
          session-test = sleeper;
          ignored-test = sleeper;
        };

        specialisation = lib.mapAttrs (_: configuration: { inherit configuration; }) {
          good = { };
          broken.systemd.services.sshd.preStart = lib.mkAfter "exit 1";
          session.systemd.services.session-breaker = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Type = "oneshot";
            script = ''
              systemctl --user -M ${user}@ kill --signal=KILL session-test.service ignored-test.service
            '';
          };
          bootfail.boot.loader.limine.extraInstallCommands = "exit 1";
          cycle.systemd.services = {
            cycle-a = {
              wantedBy = [ "multi-user.target" ];
              after = [ "cycle-b.service" ];
              script = "true";
            };
            cycle-b = {
              wantedBy = [ "multi-user.target" ];
              after = [ "cycle-a.service" ];
              script = "true";
            };
          };
        };
      };

    testScript = ''
      deploy_sh = "${../deploy.sh}"
      USER = "${user}"
      HOST = "${host}"
      ${builtins.readFile ./deploy-script/test.py}
    '';
  };
}
