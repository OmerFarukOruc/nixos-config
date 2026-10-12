# Names of every base16 scheme in the pinned tinted-theming schemes input.
{ inputs, lib }:
lib.pipe (builtins.readDir "${inputs.base16-schemes}/base16") [
  builtins.attrNames
  (lib.filter (lib.hasSuffix ".yaml"))
  (map (lib.removeSuffix ".yaml"))
]
