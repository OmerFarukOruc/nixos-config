{ pkgs, ... }:
let
  heavy = pkgs.writeShellApplication {
    name = "heavy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      [[ $# -gt 0 ]] || { echo "usage: heavy <command> [argument...]" >&2; exit 2; }
      if [[ -n ''${HEAVY_ACTIVE:-} ]]; then exec "$@"; fi
      export HEAVY_ACTIVE=1
      exec systemd-run --user --scope --quiet --collect \
        -p MemoryHigh=10G -p MemoryMax=14G -p MemorySwapMax=4G \
        nice -n 10 "$@"
    '';
  };
in
{
  home.packages = [ heavy ];
}
