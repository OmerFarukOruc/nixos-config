{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.machine) bootloader biosDevice secureBoot;
  limine = config.boot.loader.limine;
  systemThemeValues = import ./system-theme-values.nix { inherit lib; };
  menuGenerationsLikeAngrrKeepLatest =
    config.services.angrr.settings.profile-policies.system.keep-latest-n;

  rawLoader = "${limine.package}/share/limine/BOOTX64.EFI";
  esp = config.boot.loader.efi.efiSysMountPoint;
  loader = "${esp}/efi/limine/BOOTX64.EFI";
  fallbackLoader = "${esp}/efi/boot/BOOTX64.EFI";
  signingKey = "/var/lib/secure-boot/db.key";
  signingCertificate = "/var/lib/secure-boot/db.pem";
  efiVariables = "/sys/firmware/efi/efivars";

  signLimine = pkgs.writeShellApplication {
    name = "sign-limine";
    runtimeInputs = [ pkgs.sbsigntool ];
    text = ''
      sbsign --key ${signingKey} --cert ${signingCertificate} --output "$2" "$1"
      sbverify --cert ${signingCertificate} "$2"
    '';
  };

  checkSigningKey = pkgs.writeShellApplication {
    name = "check-limine-signing-key";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
      signLimine
    ];
    text = ''
      hex() {
        od --address-radix=n --format=x1 --output-duplicates "$@" | tr --delete ' \n'
      }

      scratch=$(mktemp --directory)
      trap 'rm --recursive "$scratch"' EXIT
      sign-limine ${rawLoader} "$scratch/BOOTX64.EFI" || {
        echo 'The key in ${signingKey} cannot sign Limine, so the boot loader install does not start and /boot is unchanged (docs/recovery.md, Secure Boot).' >&2
        exit 1
      }

      secure_boot=${efiVariables}/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
      if [[ -e $secure_boot && $(hex --skip-bytes=4 "$secure_boot") == 01 ]]; then
        certificate=$(openssl x509 -in ${signingCertificate} -outform DER | hex)
        [[ $(hex ${efiVariables}/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f) == *"$certificate"* ]] || {
          echo 'The firmware enforces Secure Boot and its db lacks the certificate ${signingCertificate}, so the boot loader install does not start and /boot is unchanged (docs/recovery.md, Secure Boot).' >&2
          exit 1
        }
      fi
    '';
  };

  signInstalledLimine = pkgs.writeShellApplication {
    name = "sign-installed-limine";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.sbsigntool
      signLimine
    ];
    text = ''
      loader=${lib.escapeShellArg loader}
      fallback=${lib.escapeShellArg fallbackLoader}

      replace() {
        sync --file-system "$1"
        mv "$1" "$2"
        sync --file-system "$2"
      }

      set -o errtrace
      trap 'echo "Signing Limine failed: $loader may be unsigned, and $fallback keeps the last signed copy (docs/recovery.md, Secure Boot)." >&2' ERR

      if ! sbverify --cert ${signingCertificate} "$loader" >/dev/null 2>&1; then
        sign-limine "$loader" "$loader.signed"
        replace "$loader.signed" "$loader"
      fi
      if ! cmp --silent "$loader" "$fallback"; then
        mkdir --parents "$(dirname "$fallback")"
        cp "$loader" "$fallback.signed"
        replace "$fallback.signed" "$fallback"
      fi
    '';
  };
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
        additionalFiles = lib.optionalAttrs (!limine.efiInstallAsRemovable && !secureBoot) {
          "efi/boot/BOOTX64.EFI" = rawLoader;
        };
        biosSupport = biosDevice != null;
        biosDevice = lib.mkIf (biosDevice != null) biosDevice;
        maxGenerations = menuGenerationsLikeAngrrKeepLatest;
        style = {
          wallpapers = [ ];
        }
        // systemThemeValues.limineStyle config.scheme;
      };
    })

    (lib.mkIf secureBoot {
      assertions = [
        {
          assertion = !limine.efiInstallAsRemovable;
          message = "oruc.machine.secureBoot signs \\EFI\\limine\\BOOTX64.EFI and keeps the last signed copy at the fallback path, so ${config.oruc.machine.name} cannot install Limine as removable.";
        }
        {
          assertion = !limine.secureBoot.enable;
          message = "oruc.machine.secureBoot signs Limine without an enrolled limine.conf, so ${config.oruc.machine.name} cannot also set boot.loader.limine.secureBoot.enable, which enrolls it.";
        }
      ];

      environment.systemPackages = [
        pkgs.sbsigntool
        signInstalledLimine
      ];

      system.build.signInstalledLimine = signInstalledLimine;

      system.preSwitchChecks.limineSigningKey = ''
        case "$2" in
          switch | boot) ${lib.getExe checkSigningKey} ;;
        esac
      '';

      boot.loader.limine.extraInstallCommands = lib.mkBefore (lib.getExe signInstalledLimine);

      systemd.services.limine-signature = {
        description = "Sign Limine again after an install that left it unsigned";
        wantedBy = [ "multi-user.target" ];
        before = [ "nixos-upgrade.service" ];
        unitConfig.RequiresMountsFor = esp;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe signInstalledLimine;
          ExecStop = lib.getExe signInstalledLimine;
        };
      };
    })
  ];
}
