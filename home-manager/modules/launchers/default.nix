_:
let
  selectors = import ../../../machines/selectors.nix;
in
{
  imports = map (name: ./. + "/${name}.nix") selectors.launcherNames;
}
