{ lib, pkgs, ... }:
let
  phone = "oneplus-5t:5555";
  adbServer = pkgs.writeShellApplication {
    name = "adb-server";
    runtimeInputs = with pkgs; [
      android-tools
      coreutils
    ];
    text = builtins.readFile ./adb-server.sh;
  };
in
{
  home.packages = [ pkgs.android-tools ];
  home.sessionVariables.ANDROID_SERIAL = phone;

  systemd.user.services.adb-server = {
    Unit = {
      Description = "Shared adb server that keeps Omer's OnePlus 5T connected over Tailscale";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Environment = [ "ADB_PHONE=${phone}" ];
      ExecStart = lib.getExe adbServer;
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
