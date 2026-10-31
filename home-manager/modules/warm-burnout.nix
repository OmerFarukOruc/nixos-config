{ inputs, pkgs }:
let
  inherit ((builtins.fromJSON (builtins.readFile "${inputs.warm-burnout}/vscode/package.json")))
    version
    ;
in
{
  nvim = pkgs.vimUtils.buildVimPlugin {
    pname = "warm-burnout";
    inherit version;
    src = "${inputs.warm-burnout}/nvim";
  };
  vscode = pkgs.vscode-utils.buildVscodeExtension {
    pname = "felip3fdl-warm-burnout";
    inherit version;
    src = inputs.warm-burnout;
    sourceRoot = "source/vscode";
    vscodeExtPublisher = "felip3fdl";
    vscodeExtName = "warm-burnout";
    vscodeExtUniqueId = "felip3fdl.warm-burnout";
  };
}
