# The CLIs that the coding agents call, on every machine where Omer runs them:
# the workstations (profiles/personal.nix) and risoluto-dev-1.
{ agents, pkgs, ... }:
{
  home.packages = [
    agents.agent-browser
    agents.pi
    pkgs.mitmproxy
  ];
}
