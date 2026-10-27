#!/usr/bin/env bash
# Runs as root on a server from self-deploy-reboot.service. Reboots the host
# when the kernel or the initrd that booted is not the running system's, as a
# deploy since the boot has changed them. NixOS's own check for an upgrade
# reboot also compares kernel-modules, which holds the modules the running
# kernel loads, so this does too.
# Each skip says why at priority warning (a leading <N> sets the priority of a
# journal line) and exits 0, and the next night tries again.
set -euo pipefail

booted=/run/booted-system
current=/run/current-system
profile=/nix/var/nix/profiles/system
state_dir=$HOME/.local/state/nixos-config-deploy

warn() { printf '<4>%s\n' "$*" >&2; }

differs=()
for part in kernel initrd kernel-modules; do
  [[ $(readlink -f "$booted/$part") == "$(readlink -f "$current/$part")" ]] || differs+=("$part")
done
if ((${#differs[@]} == 0)); then
  echo "The running system has the kernel and initrd that booted. No reboot."
  exit 0
fi

# A reboot starts the boot default, which must be the running system, or the
# reboot would drop what runs now (a test deploy leaves the boot default behind).
if [[ $(readlink -f "$profile") != "$(readlink -f "$current")" ]]; then
  warn "The booted ${differs[*]} differ from the running system's, but the boot default is not the running system. No reboot."
  exit 0
fi

# A deploy changes the host, so no reboot starts during one: not while the unit
# runs (a oneshot unit is activating then), not while deploy.sh holds its lock,
# a remote deploy included, and not while a rollback timer is armed. The lock
# stays held until this script ends.
deploy_runs() {
  case $(systemctl show -p ActiveState --value self-deploy.service) in
    activating | active | reloading) return 0 ;;
  esac
  systemctl is-active --quiet deploy-rollback.timer
}
mkdir -p -- "$state_dir"
exec 9>>"$state_dir/deploy.lock"
if ! flock -n 9 || deploy_runs; then
  warn "A deploy is under way, so the reboot for the new ${differs[*]} waits for the next night."
  exit 0
fi

# A deploy that meets this lock reads its owner from this file, as deploy.sh writes it.
printf 'self-deploy-reboot.service since %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/deploy.owner"
echo "The booted ${differs[*]} differ from the running system's. Rebooting in 1 minute."
# Returns at once, so this unit ends cleanly before the reboot starts.
shutdown -r +1 "Reboot for a new ${differs[*]}"
