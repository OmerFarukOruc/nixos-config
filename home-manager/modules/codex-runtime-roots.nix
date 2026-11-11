{
  agents,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  retainCodexRuntimes = pkgs.writeShellApplication {
    name = "retain-codex-runtimes";
    runtimeInputs = [
      agents.codex
      osConfig.nix.package
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.util-linux
    ];
    text = builtins.readFile ./codex-runtime-roots.sh;
  };
in
{
  home.activation.codexRuntimeRoots = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe' pkgs.coreutils "timeout"} --kill-after=5s 2m ${lib.getExe retainCodexRuntimes} ||
      warnEcho "Codex runtime roots could not be refreshed; see the Home Manager activation log"
  '';
}
