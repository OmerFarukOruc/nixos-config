#!/usr/bin/env bash
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

if [[ $(readlink -f "$profile") != "$(readlink -f "$current")" ]]; then
  warn "The booted ${differs[*]} differ from the running system's, but the boot default is not the running system. No reboot."
  exit 0
fi

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

printf 'self-deploy-reboot.service since %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/deploy.owner"
echo "The booted ${differs[*]} differ from the running system's. Rebooting in 1 minute."
shutdown -r +1 "Reboot for a new ${differs[*]}"
