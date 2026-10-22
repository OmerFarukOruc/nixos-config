{ pkgs, ... }:
{
  programs.git = {
    enable = true;
    # SourceGit runs git with credential.helper=manager unless told to use
    # libsecret, and only gitFull ships git-credential-libsecret.
    package = pkgs.gitFull;
    lfs.enable = true;
    settings = {
      user = {
        name = "Omer Faruk Oruc";
        email = "omerfarukoruc35@gmail.com";
      };
      init.defaultBranch = "main";
      pull.rebase = false;
      fetch.prune = true;
      # The first push of a new branch sets its upstream.
      push.autoSetupRemote = true;
      include.path = "~/.config/git/local-signing.inc";
      url."git@github.com:".pushInsteadOf = "https://github.com/";
    };
  };

  programs.gh = {
    enable = true;
    # `gh stack`: stacked PRs (github/gh-stack).
    extensions = [ pkgs.gh-stack ];
    settings = {
      git_protocol = "ssh";
      prompt = "enabled";
    };
  };
}
