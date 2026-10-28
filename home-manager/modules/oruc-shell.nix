# Shell setup that only oruc has. Root gets none of it. sudo starts no user
# manager for root, so no Atuin daemon socket exists, and /root has no dotfiles
# checkout.
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
    initContent = lib.mkOrder 1500 ''
      # One line when the last desktop-sync run reported a problem.
      sync_status=~/Desktop/workspace/dotfiles/desktop/shell/sync-status.zsh
      [[ -r $sync_status ]] && . "$sync_status"
      unset sync_status
    '';
  };

  programs.atuin = {
    daemon.enable = true;
    settings = {
      search_mode = "daemon-fuzzy";
    };
  };

  # Home Manager supplies both units. Only the socket starts automatically;
  # opening it asks systemd to start the daemon service on demand.
  systemd.user.services.atuin-daemon.Install.WantedBy = lib.mkForce [ ];
}
