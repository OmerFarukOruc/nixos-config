# colgrep with its search agent on the GPU: the encoder on CUDA and the agent on
# nixpkgs' Vulkan llama.cpp, which the binary cache holds.
{
  lib,
  pkgs,
  ...
}:
let
  colgrep = pkgs.callPackage ../../pkgs/colgrep.nix { };
  llamaServer = lib.getExe' pkgs.llama-cpp-vulkan "llama-server";
in
{
  home.packages = [
    colgrep
    pkgs.llama-cpp-vulkan
  ];

  # colgrep keeps its settings in a writable config.json, so each switch sets
  # these keys and leaves the others to `colgrep settings`. In hybrid mode its
  # Claude Code hooks suggest plain colgrep for names and patterns and
  # `colgrep --agent` for questions about behaviour.
  home.activation.colgrepSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${lib.getExe colgrep} settings --hook-mode hybrid --agent-llama-server ${llamaServer} >/dev/null \
      || warnEcho "colgrep's settings are unchanged; run colgrep settings by hand."
  '';
}
