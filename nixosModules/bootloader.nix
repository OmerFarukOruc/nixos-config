{
  config,
  lib,
  ...
}:
let
  inherit (config.oruc.machine) bootloader biosDevice;
  limine = config.boot.loader.limine;
  # Every listed generation keeps a kernel and initrd on the ESP. The menu lists
  # the newest this many generations, which is also angrr's newest-N rule. angrr
  # keeps older generations too (one per day, the running one and the booted
  # one); they stay in the profile without a menu entry.
  generations = config.services.angrr.settings.profile-policies.system.keep-latest-n;
in
{
  config = lib.mkMerge [
    # A server on firmware that has no writable NVRAM sets it to false.
    { boot.loader.efi.canTouchEfiVariables = lib.mkDefault true; }

    (lib.mkIf (bootloader == "systemd-boot") {
      # Secure Boot must be off in the firmware.
      boot.loader.systemd-boot = {
        enable = true;
        configurationLimit = generations;
      };
    })

    (lib.mkIf (bootloader == "limine") {
      boot.loader.limine = {
        enable = true;
        efiSupport = true;
        # The binary goes to \EFI\limine and gets its own NVRAM entry. A copy
        # at the firmware fallback path boots the same menu after the firmware
        # forgets its entries, for example after a BIOS update. Without
        # canTouchEfiVariables, nixpkgs installs the binary at the fallback path
        # only, and there is nothing to copy.
        # This is the file the installer wrote to \EFI\limine, as long as
        # enrollConfig and secureBoot stay off; the installer would enroll or
        # sign that copy in place and leave this one raw.
        additionalFiles = lib.optionalAttrs (!limine.efiInstallAsRemovable) {
          "efi/boot/BOOTX64.EFI" = "${limine.package}/share/limine/BOOTX64.EFI";
        };
        # The BIOS stage goes on the record's disk, next to the EFI loader.
        biosSupport = biosDevice != null;
        biosDevice = lib.mkIf (biosDevice != null) biosDevice;
        maxGenerations = generations;
        # A solid menu in the machine's base16 scheme, without a wallpaper.
        style =
          let
            inherit (config) scheme;
            palette = names: lib.concatMapStringsSep ";" (name: scheme.${name}) names;
          in
          {
            wallpapers = [ ];
            backdrop = scheme.base00;
            interface = {
              brandingColor = scheme.base0A;
              helpColor = scheme.base0C;
              helpColorBright = scheme.base09;
            };
            graphicalTerminal = {
              palette = palette (lib.take 8 config.oruc.theme.ansi);
              brightPalette = palette (lib.drop 8 config.oruc.theme.ansi);
              foreground = scheme.base06;
              brightForeground = scheme.base06;
              background = scheme.base00;
              brightBackground = scheme.base02;
            };
          };
      };
    })
  ];
}
