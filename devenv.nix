# The dev shell and the checks a change passes before it lands on main. direnv
# loads it through .envrc and installs the git hooks below. GitHub builds only
# the kernel (.github/workflows/kernel-cache.yml) and checks the updates of
# .github/workflows/update.yml; every other check runs on the host that commits.
{ config, pkgs, ... }:
let
  # heavy caps the memory of a heavy command on nixos-rog and nixos-desktop
  # (docs/nixos-rog.md, Heavy commands); other hosts run the command as it is.
  heavy =
    command:
    "bash -c 'if command -v heavy >/dev/null; then exec heavy ${command}; else exec ${command}; fi'";
in
{
  packages = with pkgs; [
    deadnix
    jq
    keep-sorted
    lychee
    nixfmt
    shellcheck
    shfmt
    sops
    ssh-to-age
    statix
  ];

  git-hooks.hooks = {
    # nix fmt rewrites what it formats. pre-commit then stops the commit, and a
    # second git add takes the rewrite.
    nix-fmt = {
      enable = true;
      name = "nix fmt";
      entry = "nix fmt";
      pass_filenames = false;
      always_run = true;
    };
    # prek sets unstaged edits aside before a hook runs, so the checks see the
    # staged tree. That is the pushed tree only when everything staged is
    # committed and the push sends HEAD.
    checks = {
      enable = true;
      name = "ci/checks.sh";
      entry = heavy "ci/checks.sh";
      pass_filenames = false;
      always_run = true;
      stages = [ "pre-push" ];
    };
    unit-cycles = {
      enable = true;
      name = "ci/unit-cycles.sh";
      entry = heavy "ci/unit-cycles.sh";
      pass_filenames = false;
      always_run = true;
      stages = [ "pre-push" ];
    };
  };

  # devenv test runs ci:checks and ci:unit-cycles; devenv tasks run ci also
  # builds every host's system. Each task waits for the one before it, so at
  # most one heavy scope runs at a time.
  tasks = {
    "ci:checks" = {
      exec = heavy "ci/checks.sh";
      cwd = config.devenv.root;
      before = [ "devenv:enterTest" ];
    };
    "ci:unit-cycles" = {
      exec = heavy "ci/unit-cycles.sh";
      cwd = config.devenv.root;
      after = [ "ci:checks" ];
      before = [ "devenv:enterTest" ];
    };
    "ci:build-hosts" = {
      exec = heavy "ci/build-hosts.sh";
      cwd = config.devenv.root;
      after = [ "ci:unit-cycles" ];
    };
  };
}
