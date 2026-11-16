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

  certificateTrusted = pkgs.writeShellApplication {
    name = "limine-certificate-trusted";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    text = ''
      hex() {
        od --address-radix=n --format=x1 --output-duplicates "$@" | tr --delete ' \n'
      }

      variable_data() {
        local attributes_and_data
        attributes_and_data=$(hex "${efiVariables}/$1") && echo "''${attributes_and_data:8}"
      }

      [[ -e /sys/firmware/efi ]] || exit 0

      enforced=$(variable_data SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c) || enforced=unreadable
      case $enforced in
        00) exit 0 ;;
        01) ;;
        *)
          echo 'This system booted through UEFI and its SecureBoot variable in ${efiVariables} cannot be read, so nothing shows whether the firmware trusts the certificate ${signingCertificate} (docs/recovery.md, Secure Boot).' >&2
          exit 1
          ;;
      esac

      little_endian() {
        echo $((16#''${1:6:2}''${1:4:2}''${1:2:2}''${1:0:2}))
      }

      db_holds() {
        local x509_list=a159c0a5e494a74a87b5ab155c2bf072 list=0 list_size header_size entry_size entry
        while ((list + 56 <= ''${#db})); do
          list_size=$(($(little_endian "''${db:list+32:8}") * 2))
          header_size=$(($(little_endian "''${db:list+40:8}") * 2))
          entry_size=$(($(little_endian "''${db:list+48:8}") * 2))
          ((list_size >= 56 && entry_size > 32)) || return 1
          if [[ ''${db:list:32} == "$x509_list" ]] && ((entry_size == 32 + ''${#1})); then
            for ((entry = list + 56 + header_size; entry + entry_size <= list + list_size; entry += entry_size)); do
              [[ ''${db:entry+32:entry_size-32} != "$1" ]] || return 0
            done
          fi
          list=$((list + list_size))
        done
        return 1
      }

      certificate=$(openssl x509 -in ${signingCertificate} -outform DER | hex)
      db=$(variable_data db-d719b2cb-3d3a-4596-a3bc-dad00e67656f) || db=
      if [[ -z $certificate ]] || ! db_holds "$certificate"; then
        echo 'The firmware enforces Secure Boot and its db lacks the certificate ${signingCertificate} (docs/recovery.md, Secure Boot).' >&2
        exit 1
      fi
    '';
  };

  checkSigningKey = pkgs.writeShellApplication {
    name = "check-limine-signing-key";
    runtimeInputs = [
      pkgs.coreutils
      signLimine
      certificateTrusted
    ];
    text = ''
      unchanged='the boot loader install does not start and /boot is unchanged'

      scratch=$(mktemp --directory)
      trap 'rm --recursive "$scratch"' EXIT
      sign-limine ${rawLoader} "$scratch/BOOTX64.EFI" || {
        echo "The key in ${signingKey} cannot sign Limine, so $unchanged (docs/recovery.md, Secure Boot)." >&2
        exit 1
      }
      limine-certificate-trusted || {
        echo "Limine would be signed with a certificate the firmware may refuse, so $unchanged." >&2
        exit 1
      }
    '';
  };

  signInstalledLimine = pkgs.writeShellApplication {
    name = "sign-installed-limine";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
      pkgs.sbsigntool
      signLimine
      certificateTrusted
    ];
    text = ''
      loader=${lib.escapeShellArg loader}
      fallback=${lib.escapeShellArg fallbackLoader}
      replaced=()

      set -o errtrace
      trap 'echo "Signing Limine failed after it replaced ''${replaced[*]:-no file}. Check $loader and $fallback with sbverify (docs/recovery.md, Secure Boot)." >&2' ERR

      limine-certificate-trusted

      find "$(dirname "$loader")" -maxdepth 1 -name 'signing.*' -mmin +1440 -exec rm --recursive {} +
      staging=$(
        trap - ERR
        mktemp --directory "$(dirname "$loader")/signing.XXXXXX"
      )
      trap 'rm --recursive --force "$staging"' EXIT
      candidate=$staging/candidate

      verified() {
        sbverify --cert ${signingCertificate} "$1" >/dev/null 2>&1
      }

      publish() {
        cp "$candidate" "$staging/publish"
        verified "$staging/publish"
        sync --file-system "$staging/publish"
        mv "$staging/publish" "$1"
        replaced+=("$1")
        sync --file-system "$1"
      }

      if verified "$loader"; then
        cp "$loader" "$candidate"
        verified "$candidate"
      else
        sign-limine "$loader" "$candidate"
        publish "$loader"
      fi
      if ! cmp --silent "$candidate" "$fallback"; then
        mkdir --parents "$(dirname "$fallback")"
        publish "$fallback"
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
          assertion = pkgs.stdenv.hostPlatform.isx86_64;
          message = "oruc.machine.secureBoot signs BOOTX64.EFI, the x86-64 name of Limine's EFI binary, so ${config.oruc.machine.name} cannot set it on ${pkgs.stdenv.hostPlatform.system}.";
        }
        {
          assertion = !limine.enrollConfig;
          message = "oruc.machine.secureBoot signs Limine without an enrolled limine.conf, so ${config.oruc.machine.name} cannot set boot.loader.limine.enrollConfig, which Limine then checks with Secure Boot on or off.";
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

      oruc.deploy.signedBootLoaders = {
        certificate = signingCertificate;
        files = [
          loader
          fallbackLoader
        ];
      };

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
