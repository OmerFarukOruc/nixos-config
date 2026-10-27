# Host context

nixos-latitude access: SSH alias `nixos-latitude`, key `~/.ssh/id_ed25519_omer`.

nixos-rog access: SSH alias `nixos-rog`, key `~/.ssh/id_ed25519_omer`.

nixos-desktop access: SSH alias `nixos-desktop`, key `~/.ssh/id_ed25519_omer`.

risoluto-dev-1 access: `ssh root@risoluto-dev-1` over Tailscale SSH. It runs Debian until its move to NixOS, so `deploy.sh` does not reach it yet.

Omer uses one SSH key, `~/.ssh/id_ed25519_omer`, on every device he works from. Each host's `authorizedKeys`, GitHub and `.sops.yaml` name its public key. The key has a password. On nixos-desktop and nixos-rog the gcr ssh-agent loads it with the password from KWallet, and an SSH command reaches that agent because `home-manager/modules/oruc-shell.nix` sets `SSH_AUTH_SOCK`. sops reads the key file and asks for the password on a terminal.

`sudo -n` works over SSH for `oruc` on nixos-desktop and nixos-rog (`security.sudo.wheelNeedsPassword` is off while `features.remoteAccess` is on, `nixosModules/connectivity.nix`). An SSH command there already has `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` set, so `systemctl --user` works; a Wayland client also needs `WAYLAND_DISPLAY`. The login session exports it to the user's systemd manager, so `systemctl --user show-environment | grep ^WAYLAND_DISPLAY=` prints the socket name, such as `wayland-1`. Do not guess it from the files in `$XDG_RUNTIME_DIR`, where leftover sockets stay.

## Language

**This PC**:
the host Omer is working on, nixos-desktop or nixos-rog. An agent runs on either; `hostname` names the agent's host, which need not be Omer's. When the conversation does not show which host Omer means, name the host in the answer, such as "nixos-rog (the laptop) builds ...".
_Avoid_: the desktop

**The laptop**:
nixos-rog, Omer's daily ASUS ROG. nixos-latitude is also a laptop, so name it by its host name; it is the home lab box.

**Login session**:
A desktop with its shell, offered by the display manager. A machine's first session is its default session.
_Avoid_: desktop (for the pair), profile

**Hybrid mode**:
The GA605WI firmware GPU mode in which the RTX 4070 is on the PCI bus and the Radeon 890M drives the panel (`dgpu_disable` 0, `gpu_mux_mode` 1).

**Integrated mode**:
The GA605WI firmware GPU mode in which the RTX 4070 is powered off and absent from the PCI bus (`dgpu_disable` 1).
_Avoid_: Eco mode
