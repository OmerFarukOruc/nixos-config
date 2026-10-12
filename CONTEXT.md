# Host context

nixos-latitude access: SSH alias `nixos-latitude`, key `~/.ssh/id_ed25519_nixos_latitude`.

nixos-rog access: SSH alias `nixos-rog`, key `~/.ssh/id_ed25519_nixos_rog`.

## Language

**Login session**:
A desktop with its shell, offered by the display manager. A machine's first session is its default session.
_Avoid_: desktop (for the pair), profile

**Hybrid mode**:
The GA605WI firmware GPU mode in which the RTX 4070 is on the PCI bus and the Radeon 890M drives the panel (`dgpu_disable` 0, `gpu_mux_mode` 1).

**Integrated mode**:
The GA605WI firmware GPU mode in which the RTX 4070 is powered off and absent from the PCI bus (`dgpu_disable` 1).
_Avoid_: Eco mode
