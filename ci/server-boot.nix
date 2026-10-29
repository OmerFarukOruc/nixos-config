{ inputs, host }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (inputs.disko.lib.testLib) makeDiskoTest;

  filesIn = suffix: dir: lib.filter (lib.hasSuffix suffix) (lib.filesystem.listFilesRecursive dir);
in
{
  devbox-boot-bios = makeDiskoTest {
    name = "devbox-bios";
    inherit pkgs;
    efi = false;
    inherit (host) extendModules;
    disko-config = ../machines/devbox/disk.nix;
    # The disks of the installer VM hold 4 GiB each, and the host's ESP alone
    # is 4 GiB. The image is sparse.
    extraInstallerConfig.virtualisation.emptyDiskImages = lib.mkForce [ 16384 ];
    extraSystemConfig =
      { config, ... }:
      {
        imports = filesIn ".nix" ./server-boot/modules;
        # The installer VM sees the target disk as /dev/vdb, and
        # makeDiskoTest moves GRUB's device there but not Limine's.
        boot.loader.limine.biosDevice = lib.mkOverride 70 (lib.head config.boot.loader.grub.devices);
      };
    extraTestScript = lib.concatStringsSep "\n" (
      [ (import ./box-names.nix host) ] ++ map builtins.readFile (filesIn ".py" ./server-boot/checks)
    );
  };
}
