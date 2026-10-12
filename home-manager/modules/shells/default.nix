_:
let
  selectors = import ../../../machines/selectors.nix;
in
{
  # Each module configures itself only when one of oruc.machine.sessions runs
  # that shell.
  imports = map (name: ./. + "/${name}.nix") selectors.shellNames;
}
