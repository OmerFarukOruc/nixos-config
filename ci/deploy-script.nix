{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  user = "deployer";
  host = "deploy-target";
  signingKey = "/var/lib/secure-boot/db.key";
  signingCertificate = "/var/lib/secure-boot/db.pem";
  loader = "/boot/EFI/BOOT/BOOTX64.EFI";
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
            extraInstallCommands = ''
              signing=$(mktemp --directory ${loader}.XXXXXX)
              ${pkgs.sbsigntool}/bin/sbsign --key ${signingKey} --cert ${signingCertificate} --output "$signing/signed" ${loader} &&
                ${pkgs.sbsigntool}/bin/sbverify --cert ${signingCertificate} "$signing/signed" &&
                mv "$signing/signed" ${loader}
              signed=$?
              rm --recursive "$signing"
              [ "$signed" = 0 ] || exit "$signed"
            '';
          };
        };
        environment.systemPackages = [
          pkgs.git
          pkgs.openssl
          pkgs.rsync
          pkgs.sbsigntool
        ];
        services.openssh.enable = true;
        services.tailscale.enable = true;
        security.sudo.wheelNeedsPassword = false;

        users.users.${user} = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          linger = true;
        };
        oruc.deploy = {
          sessionIgnore = [ "ignored-*.service" ];
          signedBootLoaders = {
            certificate = signingCertificate;
            files = [ loader ];
          };
        };
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
          unsigned.boot.loader.limine.extraInstallCommands = lib.mkForce "";
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
      signing_key = "${signingKey}"
      signing_certificate = "${signingCertificate}"
      loader = "${loader}"
      ${builtins.readFile ./deploy-script/test.py}
    '';
  };
}
