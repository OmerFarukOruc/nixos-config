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
      # Git opens the connection before the pre-push hook runs, and GitHub
      # closes an idle one: a push whose hook took 420 s failed without
      # keepalives and passed with them (2026-10-23). nixos-config's pre-push
      # checks take 190 to 224 s on nixos-rog (docs/deploy.md). Ten missed
      # keepalives, 300 s, end the connection.
      core.sshCommand = "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10";
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
