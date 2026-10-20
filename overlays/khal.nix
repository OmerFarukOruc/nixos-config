# DankMaterialShell's Home Manager module installs khal for calendar events.
# The Python builder passes sphinxBuilders as a Bash array, and the sphinx
# hook reads only its first element, so khal builds no man page and fails
# (https://github.com/NixOS/nixpkgs/issues/576161). A space-separated string
# reaches the hook whole. Drops out once the hook no longer reads the
# variable that way.
_final: prev:
let
  hook = builtins.readFile "${prev.path}/pkgs/development/interpreters/python/hooks/sphinx-hook.sh";
in
prev.lib.optionalAttrs (prev.lib.hasInfix ''eval "__sphinxBuilders=($sphinxBuilders)"'' hook) {
  khal = prev.khal.overrideAttrs (old: {
    sphinxBuilders = toString old.sphinxBuilders;
  });
}
