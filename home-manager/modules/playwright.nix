# Playwright runs the nixpkgs browsers; npm's downloaded ones do not run on
# NixOS. A project's npm Playwright must match the version of
# pkgs.playwright-driver (https://wiki.nixos.org/wiki/Playwright).
{ pkgs, ... }:
{
  home.sessionVariables = {
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };
}
