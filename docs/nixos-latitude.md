# nixos-latitude

This page holds the Dell Latitude 3550's hardware facts and the experiments
that failed on it, each with its date. The first install is in
[install-nixos-latitude.md](install-nixos-latitude.md).

Every number was measured on 2026-09-21 on kernel 7.2.4 (CachyOS LTO), one run
per condition, unless a line says otherwise. Re-measure before you rely on one.

## Hardware

- The firmware is BIOS 1.22.1. The disk is NVMe, and the GPU is the Intel
  Iris Xe.
- The BIOS thermal mode was Ultra Performance on 2026-09-21, and the kernel's
  platform profile read `performance`. Optimized may be the factory default;
  that is not confirmed.
- The embedded controller and the BIOS own the fan. The `dell-smm` driver
  reports `fan_max` 2, so the fan has 3 states and `pwm1` steps through 0, 128
  and 255. Writing `pwm1_enable=0` returns `Invalid argument` (2026-09-21).
- The platform profile is the only fan lever. `power-profiles-daemon` sets it
  on niri hosts (`nixosModules/peripherals.nix`).

## Fan and heat

- On battery at idle, the fan stays off in every profile, and package power is
  2.8 to 2.9 W.
- On AC at idle with `balanced`, the fan cycles. Three readings over 40 s were
  2196, 2234 and 0 rpm at 49 degrees C. With `performance`, the fan stays off
  up to about 60 degrees C.
- Under load on battery, `balanced` ran the fan about 500 rpm slower than
  `performance` or `quiet` at the same 13 W and about 73 degrees C. Under load
  on AC, `balanced` ran about 1000 rpm slower than `performance`.

## Power

Package power comes from `intel-rapl` (the CPU's energy counters). Reading
`/sys/class/powercap/intel-rapl:0/energy_uj` needs root. The readings below
use three 10-second windows.

- On battery, idle package power was about 2.7 W with waybar and mako, and with
  the DankMaterialShell (DMS) shell.
- On AC with the screen on, idle package power was 4.2 W with DMS and 3.9 W
  with Noctalia, measured back to back in one session. nixos-latitude runs
  Noctalia (`machines/inventory.nix`).
- A reading from battery does not compare with one from AC, or with one from
  another session state. Record the power source with every measurement.

## Measured dead ends

- **BORE kernel.** Under load with `balanced`, the fan ran 3934 to 4192 rpm at
  74 to 75 degrees C, against 3878 to 3908 rpm at 73 degrees C on the stock
  kernel. With `performance` the two kernels matched, at about 4900 rpm. Idle
  power was 0.15 to 0.3 W higher. The BORE runs had no login session, so the
  idle numbers do not compare exactly. The kernel was dropped, and no change
  was merged.
- **`scx_lavd --autopower` on this laptop.** Idle power was 0.6 W higher, and
  the `balanced` load fan ran 200 to 300 rpm faster. It was not adopted.
  nixos-rog runs the same scheduler on different hardware.
- **Manual fan control.** Writing `pwm1_enable=0` fails with `Invalid argument`
  (see Hardware), so no fan curve is possible. The test that tried it restored
  automatic control.

## Operation

- nixos-latitude gets `main` only from `./deploy.sh nixos-latitude switch`;
  nixos-rog's hourly updater builds its system but does not deploy it
  ([nixos-rog.md](nixos-rog.md#hourly-updater)).
  `scripts/affected-hosts.sh --running` lists nixos-latitude while it runs a
  system that differs from `main`. A new kernel from a deploy becomes the boot
  default and runs after the next reboot, which the item below covers.
- A reboot needs the password at nixos-latitude. Automatic login is off
  (`autoLogin` in `machines/inventory.nix`), so the greeter waits for a password. Sunshine
  streams the logged-in niri session, so remote desktop stays down until
  someone logs in. Reboot remotely only when someone is at nixos-latitude.
- On 2026-09-21 the Wi-Fi lost the access point (beacon loss) and Tailscale
  could not reach its relay for about 6 minutes. The uptime was unchanged, so
  the host had not crashed. Wait a few minutes before you treat an unreachable
  host as down.
- Run long tests on AC. A test series on 2026-09-21 stopped at 8 % battery
  with nixos-latitude not charging.

## An unexplained stop

nixos-latitude went offline for about 9 hours on 2026-09-21. The journal ended at
00:17:42 with an SSH session closing and no shutdown messages. The next boot
logged "recovering journal", "Dirty bit is set" and "uncleanly shut down", so
the power was cut or the kernel froze. The cause was not found. The pstore
(the kernel's crash-log store) was empty when read, but whether it recorded
crashes at that time is not confirmed. The battery history had already
rotated out.

`features.alwaysOn` in the machine record turns these on through
`nixosModules/always-on.nix`, so that the next such stop leaves evidence and
nixos-latitude restarts without anyone present:

- `panic=10` reboots 10 s after a kernel panic.
- `efi_pstore.pstore_disable=0` turns on EFI pstore, which the CachyOS kernel
  disables by default. `systemd-pstore` moves the stored log to
  `/var/lib/systemd/pstore`.
- `systemd.settings.Manager.RuntimeWatchdogSec = "20s"` makes systemd feed the
  hardware watchdog, so a hung system resets after 20 s, when the platform
  provides a watchdog.
- `RebootWatchdogSec = "30s"` resets a reboot that hangs after 30 s.
- `systemd.enableEmergencyMode = false` stops a failed mount after the initrd
  from ending at the emergency shell, which needs someone at the keyboard.

The repository holds these settings. It records no deployment, so check the
running host before you rely on them. These commands only read:

```
tr ' ' '\n' < /proc/cmdline | grep -E '^(panic|efi_pstore)'
cat /sys/module/efi_pstore/parameters/pstore_disable
findmnt /sys/fs/pstore
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
ls /dev/watchdog*
systemctl show -p LoadState emergency.service
```

The settings are active when the command line shows `panic=10` and
`efi_pstore.pstore_disable=0`, `pstore_disable` prints `N` (`Y` means
disabled), `findmnt` lists `/sys/fs/pstore`, the watchdog properties read
`20s` and `30s`, `/dev/watchdog0` exists, and `emergency.service` reports
`LoadState=not-found` (derived from the nixpkgs module, not observed on this
host). A missing `/dev/watchdog0` means the platform offers no
watchdog, and then a hang needs the power button.

After the next such stop, read `/var/lib/systemd/pstore` and the journal of the
previous boot first.
