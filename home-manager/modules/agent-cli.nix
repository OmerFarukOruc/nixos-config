{ agents, pkgs, ... }:
{
  home.packages = [
    agents.agent-browser
    agents.pi
    pkgs.mitmproxy
  ];
}
