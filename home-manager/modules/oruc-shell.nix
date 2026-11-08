{ lib, ... }:
{
  programs.zsh = {
    shellAliases.clauded = "claude --dangerously-skip-permissions";
    # The gcr ssh-agent sets SSH_AUTH_SOCK only in the desktop session, so a
    # command that arrives over SSH would not reach the unlocked key without this.
    envExtra = ''
      if [[ -z $SSH_AUTH_SOCK && -S $XDG_RUNTIME_DIR/gcr/ssh ]]; then
        export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/gcr/ssh
      fi
    '';
  };

  programs.atuin = {
    daemon.enable = true;
    settings = {
      search_mode = "daemon-fuzzy";
    };
  };

  systemd.user.services.atuin-daemon.Install.WantedBy = lib.mkForce [ ];
}
