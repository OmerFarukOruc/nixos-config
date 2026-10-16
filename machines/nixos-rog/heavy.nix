# heavy runs a heavy command, such as a Nix evaluation or a full test suite,
# in one of two slots, at nice 10, in its own systemd scope with a memory cap.
# Agents on fedora-desktop send their Nix work here (scripts/lib/rog-copy.sh),
# and on 16-10-2026 those evaluations left under 3 GiB of the 30 GiB free, so
# the kernel failed a page allocation and Claude Code stopped idle sessions'
# background shells. It follows the contract of infra's heavy on
# risoluto-dev-1 (roles/agent-host/files/heavy in OmerFarukOruc/infra): it
# exports HEAVY_ACTIVE=1, and a repository script that finds heavy on PATH
# while HEAVY_ACTIVE and CI are unset runs its suite through it.
#
# Measured on 16-10-2026: nix flake check of this flake peaked at 4.9 GiB and
# nixos-rog's toplevel drvPath evaluation at 7.3 GiB. Above MemoryHigh the
# kernel reclaims the scope's memory and slows it down; above MemoryMax it
# kills the command, so one runaway command cannot take the desktop down.
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
