{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
in
{
  formatter.x86_64-linux =
    let
      statix = pkgs.writeShellScript "statix-files" ''
        status=0
        for f in "$@"; do
          ${lib.getExe pkgs.statix} fix -- "$f" || status=1
          ${lib.getExe pkgs.statix} check -- "$f" || status=1
        done
        exit "$status"
      '';
    in
    pkgs.nixfmt-tree.override {
      runtimeInputs = with pkgs; [
        deadnix
        keep-sorted
        lychee
        ruff
        shellcheck
        shfmt
      ];
      # Without a tree root, treefmt outside a Git checkout falls back to the
      # directory of its config file, /nix/store, and formats the whole store.
      # This makes it fail at once instead.
      settings.tree-root-cmd = "git rev-parse --show-toplevel";
      settings.formatter = {
        deadnix = {
          command = "deadnix";
          options = [ "--edit" ];
          includes = [ "*.nix" ];
          priority = 1;
        };
        statix = {
          command = statix;
          includes = [ "*.nix" ];
          priority = 2;
        };
        keep-sorted = {
          command = "keep-sorted";
          includes = [ "*.nix" ];
          priority = 3;
        };
        nixfmt.priority = 4;
        shfmt = {
          command = "shfmt";
          options = [
            "--write"
            "--indent"
            "2"
            "--case-indent"
          ];
          includes = [ "*.sh" ];
          priority = 1;
        };
        shellcheck = {
          command = "shellcheck";
          includes = [
            "*.sh"
            "pkgs/claude-tools/bin/claude-accounts"
            "pkgs/claude-tools/bin/claude-login-browser"
          ];
          priority = 2;
        };
        ruff = {
          command = "ruff";
          options = [
            "check"
            "--no-cache"
            "--config"
            "pkgs/claude-tools/ruff.toml"
          ];
          includes = [
            "pkgs/claude-tools/bin/agent-peek"
            "pkgs/claude-tools/bin/agent-start"
            "pkgs/claude-tools/bin/agent-stop"
            "pkgs/claude-tools/bin/claude-limit-switch"
            "pkgs/claude-tools/bin/claude-rotate"
            "pkgs/claude-tools/bin/claude-usage"
            "pkgs/claude-tools/bin/orch-notify"
            "pkgs/claude-tools/bin/orch-watch"
          ];
        };
        lychee = {
          command = "lychee";
          options = [
            "--offline"
            "--include-fragments"
            "--no-progress"
          ];
          includes = [ "*.md" ];
        };
        exit-codes = {
          command = lib.getExe pkgs.bash;
          options = [ "scripts/check-exit-codes.sh" ];
          includes = [
            "deploy.sh"
            "docs/deploy.md"
            "scripts/pull-main.sh"
          ];
        };
        theme-drift = {
          command = lib.getExe pkgs.bash;
          options = [ "scripts/check-theme-drift.sh" ];
          includes = [ "*" ];
        };
        doc-contents = {
          command = lib.getExe pkgs.bash;
          options = [ "scripts/check-doc-contents.sh" ];
          includes = [ "*.md" ];
        };
      };
    };
}
