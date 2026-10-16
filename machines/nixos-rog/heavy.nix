# heavy runs a heavy command, such as a Nix evaluation or a full test suite, in
# one of two slots, at nice 10, in its own systemd scope with a memory cap. It
# follows the contract of infra's heavy on risoluto-dev-1: it exports
# HEAVY_ACTIVE=1, and a repository script that finds heavy on PATH while
# HEAVY_ACTIVE and CI are unset runs its suite through it. docs/nixos-rog.md,
# Heavy commands, explains why and how the caps were chosen.
{ pkgs, ... }:
let
  heavy = pkgs.writeShellApplication {
    name = "heavy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.parallel
      pkgs.systemd
    ];
    text = ''
      [[ $# -gt 0 ]] || { echo "usage: heavy <command> [argument...]" >&2; exit 2; }
      if [[ -n ''${HEAVY_ACTIVE:-} ]]; then exec "$@"; fi
      export HEAVY_ACTIVE=1
      exec sem --will-cite --id heavy -j 2 --fg --ungroup -q \
        systemd-run --user --scope --quiet --collect \
          -p MemoryHigh=10G -p MemoryMax=14G -p MemorySwapMax=4G \
          nice -n 10 "$@"
    '';
  };
in
{
  home.packages = [ heavy ];
}
