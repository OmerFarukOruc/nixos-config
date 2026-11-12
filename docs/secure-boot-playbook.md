# Secure Boot playbook for a Linux and Windows dual boot

A procedure for a coding agent that helps its user turn UEFI Secure Boot on,
on a PC that boots Linux with an unsigned boot loader and Windows from a
second disk or partition. The usual reason is a Windows game whose anti-cheat
refuses to start while Secure Boot is off.

The result keeps the firmware's factory keys, adds one certificate of the
user's own to the firmware's list of allowed signers (`db`), and signs the
Linux boot loader with that certificate's key on every install. Windows keeps
booting from Microsoft's own signed loader.

It was run once, on 2026-11-12, on the machine in
[What was tested](#what-was-tested). Everything outside that section is the
method, and each step carries its own check, so a different board or boot
loader shows where it differs.

## Rules for the agent

- **Measure before you propose.** Every command in step 1 only reads.
- **Ask before each write** to the firmware, an EFI variable, the EFI system
  partition (ESP) or the system configuration. Show the plan once, with the
  rollback, and wait for the user's approval.
- **The private key stays on the PC.** Never print it, copy it off the
  machine or commit it.
- **One firmware step per message.** The user is in the firmware setup and
  reads you on a second device. Give one action, say what the screen should
  show next, and wait for the report.
- **Read every confirmation dialog before the user answers it.** Ask for the
  text or a photo. Firmware menus put a destructive entry beside the one you
  want, and they confirm with the same "Yes".
- **Each step ends on its check.** Do not go on while a check fails.
- **Say what you tested and what you did not.** A game you did not start is
  untested.

## Step 1: measure

Run these on Linux and keep the output.

| Question | Command |
| --- | --- |
| Is Secure Boot on, and in which mode? | `bootctl status \| grep -i 'secure boot'` or `mokutil --sb-state` |
| Which keys does the firmware hold? | `efi-readvar -v PK`, `-v KEK`, `-v db`, and `efi-readvar -v dbx \| grep -c Hash` (package `efitools`) |
| Which boot entries exist, in which order? | `efibootmgr` |
| Which boot loader starts Linux, and from which file? | the `efibootmgr` entry, then `ls` on the ESP |
| Is that file signed? | `sbverify --list <file>` (package `sbsigntool` or `sbsigntools`) |
| Does the kernel lock down under Secure Boot? | `cat /sys/kernel/security/lockdown` |
| Is the Windows disk encrypted? | in Windows, as administrator: `manage-bde -status C:` |

Done when you know these four facts:

1. The factory keys are present (a vendor PK, Microsoft's KEK and `db`
   certificates). If the firmware is in Setup Mode with no keys, load the
   factory keys in the firmware first.
2. Which file the firmware starts for Linux, and whether a fallback copy
   exists at `EFI/BOOT/BOOTX64.EFI`.
3. Whether BitLocker or Device Encryption protects the Windows disk. If it
   does, the user saves the recovery key off the PC before any firmware
   change, and tells you only that it is saved.
4. The board model and firmware version, for step 2.

## Step 2: research this board and this boot loader

Read primary sources: the board's firmware manual, the boot loader's own
documentation and source, and the game's support page. Search for reports
from the same board. Find:

- the firmware menu path that appends a certificate to `db`, and the entries
  beside it that replace or delete `db`;
- whether the firmware has a setting that runs unsigned loaders even while
  Secure Boot reads "Enabled" (MSI calls it "Secure Boot Preset:
  Hardware/OS Compatibility");
- what the boot loader verifies once it is signed, and whether it then needs
  the kernel or its own config signed or hashed as well;
- what the game's anti-cheat says about custom keys.

A second model's opinion helps here. When two sources disagree, the primary
source settles it. Write down which source settled each point.

Done when you can name the exact menu entries the user will pick and the
entries the user must never pick.

## Step 3: choose the approach

Default to this one, and say why you leave it when you do:

| Choice | Default | Reason |
| --- | --- | --- |
| Firmware keys | keep the factory PK, KEK, `db` and `dbx`; append one own certificate to `db` | Windows and its key updates expect the vendor's PK, and anti-cheat reports mention custom key sets |
| Linux loader | keep the current one and sign it | no change to the boot menu or the recovery steps |
| Windows start | from the firmware, not chain-loaded | the Linux loader stays out of the boot chain that anti-cheat measures |
| Rollback | "Secure Boot: Disabled" in the firmware | it must restore both systems at every step |

Check the rollback against step 2. A loader that stores a hash of its config
inside its own binary may refuse to boot after a config change even with
Secure Boot off; then the rollback is no longer one firmware switch.

Done when the user approved the plan, the rollback and the list of writes.

## Step 4: sign the loader with Secure Boot still off

1. Create the key and certificate as root, in a folder only root reads:

   ```sh
   install -d -m 0700 /var/lib/secure-boot
   openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 10950 \
     -subj '/CN=<hostname> Secure Boot/' \
     -keyout /var/lib/secure-boot/db.key -out /var/lib/secure-boot/db.pem
   ```

2. Sign the loader to a temporary name, verify it, then rename it over the
   original. Do the same for the fallback copy:

   ```sh
   sbsign --key /var/lib/secure-boot/db.key --cert /var/lib/secure-boot/db.pem \
     --output <loader>.signed <loader>
   sbverify --cert /var/lib/secure-boot/db.pem <loader>.signed
   mv <loader>.signed <loader>
   ```

   `sbverify --cert` is the check. `sbsign` can exit 0 without writing its
   output, and `sbctl verify` reports success for an unsigned file.

3. Make every later install sign again: a hook of the distribution's boot
   loader installer, or of the package manager for the loader's package. The
   hook fails the install when signing fails, so an unsigned loader never
   lands silently. Prove it by moving the key aside and running an install:
   it must fail and leave the ESP unchanged.

4. If the Linux loader's menu starts Windows, make that entry hand over to
   the firmware instead of loading Windows itself. In Limine that is
   `protocol: efi_boot_entry` with `entry: Windows Boot Manager`.

5. Put the certificate on the ESP in the two formats firmware menus accept:

   ```sh
   openssl x509 -in /var/lib/secure-boot/db.pem -outform DER -out <ESP>/<hostname>-db.cer
   cert-to-efi-sig-list /var/lib/secure-boot/db.pem <ESP>/<hostname>-db.esl
   ```

Done when both loader copies pass `sbverify --cert`, the PC still boots Linux
and Windows with Secure Boot off, and the failed-install proof ran.

## Step 5: firmware, first visit, factory keys only

The user turns Secure Boot on and sets the firmware to refuse unsigned
loaders, and does not touch the keys.

Done when the firmware refuses the Linux loader. That refusal proves the
firmware enforces signatures; a Linux that boots here means the setting from
step 2 still lets unsigned loaders through. Note what the firmware does after
the refusal, because some start the next boot entry.

Then, in Windows: `Confirm-SecureBootUEFI` prints `True`, the disk
encryption state is what step 1 found, and the game starts. This is the
baseline with factory keys.

## Step 6: firmware, second visit, append the certificate

One action per message:

1. Open the `db` entry's menu and send its entries before picking one.
2. Pick the append entry. Read the dialog. A question such as "load factory
   default or load from a file" takes the file answer.
3. Pick the ESP, then the `.cer` file, then the certificate format. Take the
   `.esl` file when the firmware refuses the `.cer`.
4. Confirm only a dialog that says it updates or appends `db`.
5. Read the `db` row: one key more than before.
6. Save and restart.

Done when the Linux loader's menu appears and Linux boots.

If the user deletes `db` by accident, do not leave the setup. The same menu
restores the factory list (on MSI: "Set New Var", answered "Yes" to the
factory default). Then append the certificate.

## Step 7: verify on Linux, then on Windows

| Check | Expected |
| --- | --- |
| `bootctl status \| grep -i 'secure boot'` | enabled |
| `efi-readvar -v db` | the factory certificates plus the new one |
| `efi-readvar -v PK`, `dbx` hash count | unchanged from step 1 |
| `sbverify --cert` on both loader copies | OK |
| `systemctl --failed` | empty |
| `cat /sys/kernel/security/lockdown` | compare with step 1 |
| a full system update that reinstalls the loader | both copies still verify |
| restart from the fallback entry | same menu, Linux boots |
| `efibootmgr` | signed fallback copy ahead of Windows, when the firmware starts the next entry after a refusal |

A kernel that switches to lockdown under Secure Boot refuses unsigned kernel
modules, so an out-of-tree driver such as NVIDIA's needs a signed module, and
hibernation may stop working. Drivers that ship in the kernel, such as AMD's,
are not affected.

Then Windows, started from the Linux loader's menu: the game starts again.
A game that passed in step 5 and fails now is the only evidence against the
added certificate. Start Windows once from the firmware's boot menu and try
again before you conclude that.

## Rollback

- Set Secure Boot to Disabled in the firmware. Both systems boot as before.
- Windows starts from the firmware's boot menu at every step.
- Remove the certificate from `db`, or load the factory `db` again.
- Remove the signing hook, then the key folder and the two files on the ESP.
  Do this only after Secure Boot is off.
- When the setup is out of reach, clearing CMOS turns Secure Boot off on most
  boards. Check the board manual for the jumper or button.

## After a firmware update or a CMOS clear

The firmware may drop the certificate and its settings. Boot Linux with
Secure Boot off and repeat step 6; the certificate is still on the ESP.

## What was tested

| Part | Value |
| --- | --- |
| Board | MSI MAG B650 TOMAHAWK WIFI, BIOS `1.R3` |
| GPU | AMD Radeon RX 7900 XTX |
| Linux | NixOS 26.11, kernel lockdown `[none]` with Secure Boot on |
| Boot loader | Limine 12.9.4, signed, no enrolled config hash |
| Windows | on its own disk, not encrypted |
| Firmware keys | factory PK, KEK and `dbx` unchanged; `db` holds 6 factory certificates plus 1 own |

- **Firmware path on this board.** Settings > Security > Secure Boot: "Secure
  Boot" Enabled, "Secure Boot Mode" Custom, "Secure Boot Preset" Maximum
  Security. Key Management > "Authorized Signatures (db)" > "Append Key" >
  "No" > the ESP > the `.cer` file > "Public Key Certificate" > empty owner
  GUID > "Yes".
- **Entries to avoid on this board.** "Delete Var" and "Set New Var" in the
  same menu, "Enroll all Factory Default keys", "Delete all Secure Boot
  variables", and Secure Boot Mode Standard.
- **Refusal.** The firmware shows "Secure Boot Violation", then starts the
  next boot entry.
- **Limine.** Limine 12.9.4 boots when it is signed and holds no config hash,
  and then verifies neither its config nor the kernel. Secure Boot therefore
  covers only the step from the firmware to Limine. That was enough for the
  goal here and keeps the one-switch rollback.
- **Games.** Call of Duty: Modern Warfare 4 started and joined online matches
  with Secure Boot on, first with the factory keys only and again after the
  certificate was appended. FACEIT, Valorant and Battlefield 6 were not run.
- **Not tested.** GRUB, systemd-boot, shim, a unified kernel image, NVIDIA,
  BitLocker, and any other board.

The NixOS code is in [nixosModules/bootloader.nix](../nixosModules/bootloader.nix),
the host steps in [Install nixos-desktop](install-nixos-desktop.md#secure-boot),
and the recovery cases in [Recovery](recovery.md#secure-boot).

## Sources

- Limine, Secure Boot and config hash: <https://github.com/Limine-Bootloader/Limine/blob/v12.9.4/USAGE.md>
- Limine `efi_boot_entry`: <https://github.com/Limine-Bootloader/Limine/blob/v12.9.4/common/protos/efi_boot_entry.c>
- MSI AM5 BIOS guide: <https://download.msi.com/manual/mb/AMDAM5BIOS.pdf>
- sbsigntool `sbverify.c`: <https://git.kernel.org/pub/scm/linux/kernel/git/jejb/sbsigntools.git/plain/src/sbverify.c?h=v0.9.5>
- sbctl `verify.go`: <https://github.com/Foxboron/sbctl/blob/0.18/cmd/sbctl/verify.go>
- Activision, TPM and Secure Boot: <https://support.activision.com/tpm-report>
