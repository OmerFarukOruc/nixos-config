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
            "pkgs/claude-tools/libexec/claude-accounts"
            "pkgs/claude-tools/libexec/login-browser"
            "pkgs/agent-tools/bin/brave-browser"
            "pkgs/agent-tools/bin/brave-cdp"
            "pkgs/agent-tools/bin/browser-lend"
            "pkgs/agent-tools/bin/codex-ask"
            "pkgs/agent-tools/bin/dryer"
            "pkgs/agent-tools/bin/gh-issue-tree"
            "pkgs/agent-tools/bin/gh-wait-checks"
            "pkgs/agent-tools/bin/infisical-describe"
            "pkgs/agent-tools/bin/lend-cdp"
            "pkgs/agent-tools/bin/mdv"
            "pkgs/agent-tools/bin/path-claims"
            "pkgs/agent-tools/bin/pr-land"
            "pkgs/agent-tools/bin/ropen"
            "pkgs/agent-tools/bin/sandbox-run"
            "pkgs/agent-tools/bin/wait-exit"
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
            "pkgs/claude-tools/src/**/*.py"
            "pkgs/agent-tools/bin/agent-watch"
            "pkgs/agent-tools/bin/cc-setting"
            "pkgs/agent-tools/bin/cdp-eval"
            "pkgs/agent-tools/bin/oom-report"
            "pkgs/agent-tools/bin/removed-defs"
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
          # Verbatim vendor pages: their root-relative links point into the vendor's site.
          excludes = [
            "agents/reference/headless-clis/*-headless*.md"
            "agents/reference/headless-clis/chatgpt-*.md"
            "agents/reference/headless-clis/opencode-cli.md"
          ];
        };
        exit-codes = {
          command = lib.getExe pkgs.bash;
          options = [ "scripts/check-exit-codes.sh" ];
          includes = [
            "deploy.sh"
            "docs/deploy.md"
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
