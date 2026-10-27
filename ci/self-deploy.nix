# The deploy path of a server (docs/deploy.md, Self-deploy of a server) in a NixOS
# test: self-deploy.service, deploy.sh with its rollback, and the reboot unit run
# against a main that a local repository holds. The node is named
# risoluto-dev-1 because deploy.sh deploys to the host that it runs on. It
# loads nixosModules/upgrade.nix, nixosModules/deploy-host.nix and
# nixosModules/telemetry.nix (whose option deploy-host.nix sets), the modules of
# the host that carry the deploy path, and not the host's whole configuration,
# which the boot test covers.
#
# Each system that the test deploys is a specialisation of the node with one
# change, so the node's closure holds it and the test database knows it. The
# test's main holds a flake that answers for the host with that system's store
# path, which `nix build` accepts as a flake output (ci/self-deploy/test.py).
#
# Takes the inputs; returns the flake checks.
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
        # deploy.sh writes boot entries to an ESP at /boot, as on the box, which
        # runs Limine and whose ESP is 4 GiB. The ESP of qemu-vm's own boot
        # disk has 256 MiB, too little for deploy.sh's free-space check, so a
        # second disk holds it.
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
        # The test makes the main with git, and deploy.sh checks the tree with it.
        programs.git.enable = true;
        # The VM has no network. The unit clones the real URL, and git sends it to
        # the local repository that holds the test's main.
        programs.git.config.url."file:///var/lib/server-test/main.git".insteadOf =
          "https://github.com/OmerFarukOruc/nixos-config.git";

        oruc.deploy = {
          self = {
            enable = true;
            # The test writes a token of the right shape here before a run.
            githubTokenFile = "/var/lib/server-test/github-token";
          };
          sessionIgnore = [ "herdr-*.service" ];
        };

        # deploy.sh's confirmation checks both units.
        services.openssh.enable = true;
        services.tailscale.enable = true;

        # oruc keeps a sudo password, as on the box.
        users.users.oruc = {
          isNormalUser = true;
          uid = 1003;
          extraGroups = [ "wheel" ];
          initialPassword = "test";
          linger = true;
        };
        # Two user services of oruc: the session check ignores the one that
        # matches the list.
        systemd.user.services = {
          herdr-test = userSleep;
          other-test = userSleep;
        };

        specialisation = lib.mapAttrs (_: configuration: { inherit configuration; }) {
          good.environment.etc."server-test-system".text = "good";
          # The restart of sshd fails, as a bad sshd configuration would.
          broken = {
            environment.etc."server-test-system".text = "broken";
            systemd.services.sshd.preStart = lib.mkAfter "exit 1";
          };
          # Another initrd, so the booted one differs from the running system's.
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
