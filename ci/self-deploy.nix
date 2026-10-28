{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
in
{
  risoluto-dev-1-self-deploy = pkgs.testers.runNixOSTest {
    name = "risoluto-dev-1-self-deploy";

    nodes.machine =
      { pkgs, ... }:
      let
        userSleep = {
          wantedBy = [ "default.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      in
      {
        imports = [
          ../nixosModules/upgrade.nix
          ../nixosModules/deploy-host.nix
          ../nixosModules/telemetry.nix
        ];

        networking.hostName = "risoluto-dev-1";
        nix = {
          enable = true;
          settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
        };
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
        programs.git.enable = true;
        programs.git.config.url."file:///var/lib/server-test/main.git".insteadOf =
          "https://github.com/OmerFarukOruc/nixos-config.git";

        oruc.deploy = {
          self = {
            enable = true;
            githubTokenFile = "/var/lib/server-test/github-token";
          };
          sessionIgnore = [ "herdr-*.service" ];
        };

        services.openssh.enable = true;
        services.tailscale.enable = true;

        users.users.oruc = {
          isNormalUser = true;
          uid = 1003;
          extraGroups = [ "wheel" ];
          initialPassword = "test";
          linger = true;
        };
        systemd.user.services = {
          herdr-test = userSleep;
          other-test = userSleep;
        };

        specialisation = lib.mapAttrs (_: configuration: { inherit configuration; }) {
          good.environment.etc."server-test-system".text = "good";
          broken = {
            environment.etc."server-test-system".text = "broken";
            systemd.services.sshd.preStart = lib.mkAfter "exit 1";
          };
          initrd = {
            environment.etc."server-test-system".text = "initrd";
            boot.initrd.compressorArgs = [ "-1" ];
          };
        };
      };

    testScript = ''
      deploy_sh = "${../deploy.sh}"
      running_revision_sh = "${../scripts/lib/running-revision.sh}"
      ${builtins.readFile ./self-deploy/test.py}
    '';
  };
}
