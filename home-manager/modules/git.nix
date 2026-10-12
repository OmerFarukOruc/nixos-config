_: {
  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      user = {
        name = "Omer Faruk Oruc";
        email = "omerfarukoruc35@gmail.com";
      };
      init.defaultBranch = "main";
      pull.rebase = false;
      # The first push of a new branch sets its upstream.
      push.autoSetupRemote = true;
      include.path = "~/.config/git/local-signing.inc";
      url."git@github.com:".pushInsteadOf = "https://github.com/";
    };
  };

  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
      prompt = "enabled";
    };
  };
}
