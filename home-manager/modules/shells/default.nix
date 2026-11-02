_:
let
  selectors = import ../../../machines/selectors.nix;
in
{
  imports = [ ./scheme-apply.nix ] ++ map (name: ./. + "/${name}.nix") selectors.shellNames;
}
