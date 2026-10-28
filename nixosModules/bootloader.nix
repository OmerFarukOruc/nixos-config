{
  config,
  lib,
  ...
}:
let
  inherit (config.oruc.machine) bootloader biosDevice;
  limine = config.boot.loader.limine;
  menuGenerationsLikeAngrrKeepLatest =
    config.services.angrr.settings.profile-policies.system.keep-latest-n;
in
{
  config = lib.mkMerge [
    { boot.loader.efi.canTouchEfiVariables = lib.mkDefault true; }

    (lib.mkIf (bootloader == "systemd-boot") {
      boot.loader.systemd-boot = {
        enable = true;
        configurationLimit = menuGenerationsLikeAngrrKeepLatest;
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
        biosSupport = biosDevice != null;
        biosDevice = lib.mkIf (biosDevice != null) biosDevice;
        maxGenerations = menuGenerationsLikeAngrrKeepLatest;
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
