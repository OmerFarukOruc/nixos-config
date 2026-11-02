{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.shellScheme;
  applyScheme =
    shell: spec:
    pkgs.writeShellApplication {
      name = "oruc-${shell}-scheme";
      runtimeInputs = [
        pkgs.coreutils
        spec.package
        config.oruc.wallpaper
      ];
      text = ''
        for _ in $(seq 40); do
          ${spec.probe} >/dev/null 2>&1 && break
          sleep 0.5
        done
        ${lib.trim spec.steps}
      '';
    };
in
{
  options.oruc.shellScheme = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          package = lib.mkOption {
            type = lib.types.package;
            description = "The shell's package, whose CLI the probe and the steps call.";
          };
          probe = lib.mkOption {
            type = lib.types.str;
            description = "A command that succeeds once the running shell answers its CLI; the script retries it for up to 20 seconds.";
          };
          steps = lib.mkOption {
            type = lib.types.lines;
            description = "Shell commands that set the shell's colours, mode and wallpaper from the stored scheme.";
          };
        };
      }
    );
    default = { };
    description = ''
      Shells that load the stored scheme through their own CLI, by shell name.
      Each shell's user service runs the steps after it starts, and the theme
      and plasma-look switches run them while the service is active.
    '';
  };

  config = {
    systemd.user.services = lib.mapAttrs (shell: spec: {
      Service.ExecStartPost = [ "-${lib.getExe (applyScheme shell spec)}" ];
    }) cfg;
    oruc.variantReloads = lib.mapAttrs (shell: spec: ''
      systemctl --user is-active -q ${shell}.service || exit 0
      ${lib.getExe (applyScheme shell spec)}
    '') cfg;
  };
}
