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

  # The units of the dotfiles checkout start `zsh -c`, and /etc/zshenv replaces
  # their PATH, so every zsh, interactive or not, gets the CLIs that installers
  # put in the home: amp in ~/.local/bin, OpenCode in ~/.opencode/bin.
  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.opencode/bin"
  ];
}
