{
  config,
  inputs,
  pkgs,
  sessions,
  ...
}:
let
  llmAgents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  homeManagerBackup = pkgs.writeShellScript "home-manager-backup" ''
    set -euo pipefail
    target=$1
    stamp=$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)
    backup="$target.hm-backup-$stamp"
    suffix=0
    while [[ -e "$backup" || -L "$backup" ]]; do
      suffix=$((suffix + 1))
      backup="$target.hm-backup-$stamp-$suffix"
    done
    ${pkgs.coreutils}/bin/mv -- "$target" "$backup"
  '';
in
{
  nixpkgs.overlays = [
    (import ../overlays/khal.nix)
    (import ../overlays/mcp-nixos.nix)
  ];

  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupCommand = homeManagerBackup;
    extraSpecialArgs = {
      inherit inputs sessions;
      agents = llmAgents;
    };
    sharedModules = [
      inputs.nix-index-database.homeModules.nix-index
      {
        home = {
          stateVersion = "26.11";
          preferXdgDirectories = true;
        };
        xdg.enable = true;
      }
    ];
    users.${config.oruc.machine.user}.imports = [ ../home-manager/common.nix ];
    users.root.imports = [ ../home-manager/modules/shell.nix ];
  };
  users.users.root.shell = pkgs.zsh;
}
