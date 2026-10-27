# Home Manager layer of risoluto-dev-1, on top of the layer that every host
# gets (home-manager/common.nix): the hourly sync that links Omer's agent config
# from the dotfiles checkout. Once the host runs NixOS, desktop-sync.sh leaves
# the shell and the tools to Home Manager, as on the workstations. The agents'
# Playwright runs the nixpkgs browsers, as on the desktops.
{
  imports = [
    ../../home-manager/modules/desktop-sync.nix
    ../../home-manager/modules/playwright.nix
  ];
}
