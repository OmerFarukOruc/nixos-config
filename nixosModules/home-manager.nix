{
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
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  # A host adds its own layer through home-manager.users.oruc.imports.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupCommand = homeManagerBackup;
    extraSpecialArgs = {
      inherit inputs sessions;
      # The llm-agents.nix packages.
      agents = llmAgents // {
        herdr = pkgs.callPackage ../pkgs/herdr.nix { inherit (llmAgents) herdr; };
      };
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
    users.oruc.imports = [ ../home-manager/common.nix ];
    # sudo -i gets the same shell, aliases and tools as oruc.
    users.root.imports = [ ../home-manager/modules/shell.nix ];
  };
  users.users.root.shell = pkgs.zsh;
}
