{ config, lib, ... }:
let
  facts = config.oruc.verifyFacts;
in
{
  options.oruc.verifyFacts = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Name and value of each fact; names are shell variable names.";
  };

  config = lib.mkIf (facts != { }) {
    assertions = lib.mapAttrsToList (name: value: {
      assertion =
        builtins.match "[a-z_][a-z0-9_]*" name != null && builtins.match "[A-Za-z0-9._,-]+" value != null;
      message = "oruc.verifyFacts.${name} = \"${value}\" is not a plain shell name and value.";
    }) facts;

    environment.etc."oruc/verify-facts".text = lib.concatStrings (
      lib.mapAttrsToList (name: value: "${name}=${value}\n") facts
    );
  };
}
