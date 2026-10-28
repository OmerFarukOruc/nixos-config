{ config, pkgs, ... }:
let
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
    nix-fmt = {
      enable = true;
      name = "nix fmt";
      entry = "nix fmt";
      pass_filenames = false;
      always_run = true;
    };
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
