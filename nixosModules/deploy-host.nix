{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.deploy;
  signed = cfg.signedBootLoaders;
in
{
  options.oruc.deploy = {
    sessionIgnore = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "herdr-*.service" ];
      description = "Shell globs of the user services that deploy.sh's session check ignores, such as long-running agents that a switch may restart.";
    };

    signedBootLoaders = {
      certificate = lib.mkOption {
        type = lib.types.str;
        example = "/var/lib/secure-boot/db.pem";
        description = "Certificate on the host whose key signs the files in oruc.deploy.signedBootLoaders.files.";
      };
      files = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/boot/efi/limine/BOOTX64.EFI" ];
        description = "EFI binaries that the firmware refuses without a signature of oruc.deploy.signedBootLoaders.certificate. After deploy.sh installs the boot entries of this system, it checks each file with sbverify and restores the previous boot entries when one fails.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.sessionIgnore != [ ]) {
      environment.etc."nixos-config-deploy/session-ignore".text = lib.concatLines cfg.sessionIgnore;
    })
    (lib.mkIf (signed.files != [ ]) {
      environment.etc."nixos-config-deploy/verify-boot-loaders".source = lib.getExe (
        pkgs.writeShellApplication {
          name = "verify-boot-loaders";
          runtimeInputs = [ pkgs.sbsigntool ];
          text = ''
            verify() {
              sbverify --cert ${lib.escapeShellArg signed.certificate} "$1" >/dev/null || {
                printf '%s carries no signature of %s, so the firmware may refuse it.\n' "$1" ${lib.escapeShellArg signed.certificate} >&2
                exit 1
              }
            }
          ''
          + lib.concatMapStrings (file: "verify ${lib.escapeShellArg file}\n") signed.files;
        }
      );
    })
  ];
}
