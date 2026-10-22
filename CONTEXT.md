# Host context

nixos-latitude access: SSH alias `nixos-latitude`, key `~/.ssh/id_ed25519_omer`.

nixos-rog access: SSH alias `nixos-rog`, key `~/.ssh/id_ed25519_omer`.

nixos-desktop access: SSH alias `nixos-desktop`, key `~/.ssh/id_ed25519_omer`.

Omer uses one SSH key, `~/.ssh/id_ed25519_omer`, on every device he works from. Each host's `authorizedKeys`, GitHub and `.sops.yaml` name its public key. The key has a password. On nixos-desktop and nixos-rog the gcr ssh-agent loads it with the password from KWallet, and an SSH command reaches that agent because `home-manager/modules/oruc-shell.nix` sets `SSH_AUTH_SOCK`. sops reads the key file and asks for the password on a terminal.

`sudo -n` works over SSH for `oruc` on nixos-desktop and nixos-rog (`security.sudo.wheelNeedsPassword` is off while `features.remoteAccess` is on, `nixosModules/connectivity.nix`). An SSH command there already has `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` set, so `systemctl --user` works; a Wayland client also needs `WAYLAND_DISPLAY`. The Plasma session uses `wayland-0`; `ss -xl | grep wayland` lists the sockets that a compositor listens on, because leftover socket files stay in `$XDG_RUNTIME_DIR`.

## Language

**This PC**:
nixos-desktop, where an agent usually runs. An agent can also run on nixos-rog.
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
