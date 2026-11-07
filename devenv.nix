{ config, pkgs, ... }:
let
  heavy =
    command:
    "bash -c 'if command -v heavy >/dev/null; then exec heavy ${command}; else exec ${command}; fi'";
in
{
  packages = with pkgs; [
    deadnix
    gitleaks
    jq
    keep-sorted
    lychee
    nixfmt
    python3
    ruff
    shellcheck
    shfmt
    sops
    ssh-to-age
    statix
  ];

  git-hooks.hooks = {
    nix-fmt = {
      enable = true;
      name = "nix fmt";
      entry = "nix fmt --no-update-lock-file";
      pass_filenames = false;
      always_run = true;
    };
    gate = {
      enable = true;
      name = "ci/gate.sh";
      entry = heavy "ci/gate.sh";
      pass_filenames = false;
      always_run = true;
      stages = [ "pre-push" ];
    };
  };

  tasks = {
    "ci:gate" = {
      exec = heavy "ci/gate.sh";
      cwd = config.devenv.root;
      before = [ "devenv:enterTest" ];
    };
    "ci:build-hosts" = {
      exec = heavy "ci/build-hosts.sh";
      cwd = config.devenv.root;
      after = [ "ci:gate" ];
    };
  };
}
