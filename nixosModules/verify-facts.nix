# Facts a host's verify script checks the running system against, written to
# /etc/oruc/verify-facts as name=value lines that the script sources. They come
# from the deployed configuration, so the script tests the system against the
# config it runs, not against a checkout.
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
    # The script sources the file, so only plain names and values may appear.
    # A comma separates the items of a list.
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
