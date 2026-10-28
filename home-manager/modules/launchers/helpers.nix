{ lib, pkgs }:
let
  sshHosts = "if [ -r \"$HOME/.ssh/config\" ]; then ${pkgs.gawk}/bin/awk '/^[[:space:]]*Host[[:space:]]+/ { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' \"$HOME/.ssh/config\"; fi";
  fileList = "${lib.getExe pkgs.fd} --type f --hidden --exclude .git . \"$HOME\"";
  terminal = lib.getExe pkgs.ghostty;
  mkLauncher = name: text: pkgs.writeShellApplication { inherit name text; };
  launchers = {
    app = "Application launcher";
    command = "Command launcher";
    ssh = "SSH launcher";
    file = "File launcher";
  };
  binName = name: "oruc-launch-${name}";
in
{
  inherit terminal;

  sshVia = picker: ''
    choice="$(${sshHosts} | ${picker} || true)"
    [[ -z "$choice" ]] || exec ${terminal} -e ${lib.getExe' pkgs.openssh "ssh"} "$choice"
  '';
  fileVia = picker: ''
    choice="$(${fileList} | ${picker} || true)"
    [[ -z "$choice" ]] || exec ${lib.getExe' pkgs.xdg-utils "xdg-open"} "$choice"
  '';

  inherit launchers binName;

  packagesFor =
    commands:
    assert lib.attrNames commands == lib.attrNames launchers;
    lib.mapAttrsToList (name: mkLauncher (binName name)) commands;
}
