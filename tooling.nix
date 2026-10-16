{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
in
{
  # nix fmt formats and lints. treefmt runs the formatters on a file in
  # ascending priority, so nixfmt lays out what deadnix and statix rewrote.
  formatter.x86_64-linux =
    let
      # statix takes one path per run; treefmt passes many files. A finding in
      # any file fails the run.
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
          includes = [ "*.sh" ];
          priority = 2;
        };
        # Relative links and their heading anchors. --offline skips web links.
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
            "scripts/auto-update.sh"
          ];
        };
        # A fixed color in a tracked file. The script skips Markdown, lock files
        # and assets/ itself.
        theme-drift = {
          command = lib.getExe pkgs.bash;
          options = [ "scripts/check-theme-drift.sh" ];
          includes = [ "*" ];
        };
        # A document whose first list is a contents list names each of its headings.
        doc-contents = {
          command = lib.getExe pkgs.bash;
          options = [ "scripts/check-doc-contents.sh" ];
          includes = [ "*.md" ];
        };
      };
    };

  # direnv loads this through .envrc on a host with Nix.
  devShells.x86_64-linux.default = pkgs.mkShell {
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
  };
}
