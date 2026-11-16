# Secure Boot playbook for a Linux and Windows dual boot

A procedure for a coding agent that helps its user turn UEFI Secure Boot on,
on a PC that boots Linux with an unsigned boot loader and Windows from a
second disk or partition. The usual reason is a Windows game whose anti-cheat
refuses to start while Secure Boot is off.

The result keeps the firmware's factory keys, adds one certificate of the
user's own to the firmware's list of allowed signers (`db`), and signs the
Linux boot loader with that certificate's key on every install. Windows keeps
booting from Microsoft's own signed loader.

Secure Boot then covers one step, from the firmware to the Linux boot loader.
Nothing authenticates the loader's config, the kernel, the initrd or the root
file system, so this does not protect Linux from someone who can write its
disk. The factory `db` also holds Microsoft's third-party certificates, so the
firmware still starts any medium whose loader Microsoft signed, such as a
distribution's shim. That is enough for a game's anti-cheat, which is the goal
here.

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
| Which keys does the firmware hold? | `efi-readvar -v PK`, `-v KEK` and `-v db` (package `efitools`) |
| What does each key list hold, byte for byte? | `for v in PK KEK db dbx; do efi-readvar -v $v -o $v.esl; done; sha256sum *.esl`, and keep the four files |
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
| Firmware keys | keep the factory PK, KEK, `db` and `dbx`; append one own certificate to `db` | the firmware never enters Setup Mode, the `dbx` revocations stay, and it is the smallest firmware change |
| Linux loader | keep the current one and sign it | no change to the boot menu or the recovery steps |
| Windows start | from the firmware, not chain-loaded | the Linux loader stays out of the boot chain that anti-cheat measures |
| Rollback | "Secure Boot: Disabled" in the firmware | it must restore both systems at every step |

The vendor's PK matters for a later change of the KEK or of the PK itself,
which the PK must sign, and for any `db` or `dbx` update the vendor signs with
it. Microsoft signs its `db` and `dbx` updates with its key in the KEK
([Sources](#sources), Microsoft). Windows itself boots under any PK whose `db`
holds Microsoft's certificates.
[Why not sbctl](#why-not-sbctl-or-the-nixpkgs-limine-option) compares the
route that replaces the keys.

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

2. Sign the loader into a new temporary folder, verify that file, then rename
   it over the original. Do the same for the fallback copy:

   ```sh
   staging=$(mktemp --directory <loader>.XXXXXX)
   sbsign --key /var/lib/secure-boot/db.key --cert /var/lib/secure-boot/db.pem \
     --output "$staging/signed" <loader> &&
     sbverify --cert /var/lib/secure-boot/db.pem "$staging/signed" &&
     mv "$staging/signed" <loader>
   rm --recursive "$staging"
   ```

   `sbverify --cert` on the new file is the check, and the `&&` keeps a
   failed step from reaching the `mv`. `sbsign` 0.9.5 exits 0 when it cannot
   write its output (`sbsign.c` ignores the result of `image_write`), so a
   file that an earlier run left under a fixed name such as `<loader>.signed`
   would pass as this run's output. `sbctl verify` 0.18 prints "is not signed"
   for an unsigned file and still exits 0.

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
| `sha256sum` of new `efi-readvar -o` files for PK, KEK and `dbx` | the same as step 1 |
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

- Set Secure Boot to Disabled in the firmware. The firmware then starts a
  loader whatever its signature, so both systems boot as before. It repairs no
  file: a loader that is missing or damaged on the ESP still does not boot.
- Windows starts from the firmware's boot menu at every step.
- Remove the certificate from `db`, or load the factory `db` again.
- Remove the signing hook, then the key folder and the two files on the ESP.
  Do this only after Secure Boot is off.
- When the setup is out of reach, clearing CMOS resets the firmware settings.
  Whether that turns Secure Boot off or drops the added certificate differs
  from board to board, so read the board manual first, also for the jumper or
  button.

## After a firmware update or a CMOS clear

The firmware may drop the certificate and its settings. Boot Linux with
Secure Boot off and repeat step 6; the certificate is still on the ESP.

## Why not sbctl or the nixpkgs Limine option

The other route gives the firmware keys of the user's own: `sbctl enroll-keys
--microsoft`, which nixpkgs' `boot.loader.limine.secureBoot` can run from the
boot loader install. It is the route to take when Linux itself must be
authenticated. For a game's anti-cheat it changes more and adds no trust that
Windows needs.

| | This playbook | `sbctl enroll-keys --microsoft` through nixpkgs' `boot.loader.limine.secureBoot` |
| --- | --- | --- |
| PK | the vendor's | sbctl's own |
| KEK | factory | sbctl's own, Microsoft 2011 and 2023 |
| `db` | factory plus one certificate | sbctl's own plus five Microsoft certificates |
| `dbx` | unchanged | not written |
| Setup Mode | not needed | needed |
| Loader config | not hashed | hashed into Limine |

- **Setup Mode.** sbctl 0.18 writes PK, KEK and `db` whole
  (`cmd/sbctl/enroll-keys.go`), which the firmware accepts only after it
  dropped its PK. A firmware entry that deletes every Secure Boot key to get
  there empties `dbx` too, and sbctl does not write `dbx` back; deleting only
  the PK keeps it.
- **Loader config.** `boot.loader.limine.secureBoot.enable` turns on
  `enrollConfig`. Limine then refuses a config that differs from the hash in
  its binary, with Secure Boot on or off, so the rollback is no longer one
  firmware switch, and a tool that edits the config at run time, such as a
  theme switcher, must stop.
- **Exit codes.** At nixpkgs revision `d5cc6833`, `limine-install.py` runs `limine enroll-config`, `sbctl
  create-keys`, `sbctl enroll-keys` and `sbctl sign` on the loader with
  `subprocess.run` and no `check=True`, so a failed call does not fail the
  install. `grep -n -A2 'subprocess.run' limine-install.py` shows them.
- **Option ROMs.** On either route keep Microsoft's certificates in `db`. The
  firmware also checks the firmware of add-in cards (option ROMs) against
  `db`, and vendors usually sign it through Microsoft's third-party
  certificate. Without that certificate a graphics card may show no picture,
  the firmware setup included, which sbctl's FAQ calls a soft brick.

## What was tested

| Part | Value |
| --- | --- |
| Board | MSI MAG B650 TOMAHAWK WIFI, BIOS `1.R3` |
| GPU | AMD Radeon RX 7900 XTX |
| Linux | NixOS 26.11, kernel lockdown `[none]` with Secure Boot on |
| Boot loader | Limine 12.9.4, signed, no enrolled config hash |
| Windows | on its own disk, not encrypted |
| Firmware keys | PK and KEK equal the firmware's defaults; `db` holds 6 factory certificates plus 1 own; `dbx` is 700 bytes larger than the firmware's default, after an update through fwupd |

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
  and nothing then authenticates its config. It still compares the kernel and
  the initrd with the hashes in that config, and with `hash_mismatch_panic:
  no`, which the NixOS installer writes by default, a mismatch prints a
  warning and boots after the user presses `Y` (`uri_hash_mismatch` in
  `common/lib/uri.c`). Secure Boot
  therefore covers only the step from the firmware to Limine. That was enough
  for the goal here and keeps the one-switch rollback.
- **Fallback copy.** The copy at `EFI/BOOT/BOOTX64.EFI` is the last signed
  duplicate of the same Limine and reads the same config and kernels. It boots
  after an install that left the first copy unsigned or after the firmware
  lost its boot entries. It does not help against a Limine release that does
  not boot, because the next signing run copies that release there too.
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
- Limine, enrolled config hash (`init_config`): <https://github.com/Limine-Bootloader/Limine/blob/v12.9.4/common/lib/config.c>
- Limine, file hash mismatch (`uri_hash_mismatch`): <https://github.com/Limine-Bootloader/Limine/blob/v12.9.4/common/lib/uri.c>
- Limine `efi_boot_entry`: <https://github.com/Limine-Bootloader/Limine/blob/v12.9.4/common/protos/efi_boot_entry.c>
- MSI AM5 BIOS guide: <https://download.msi.com/manual/mb/AMDAM5BIOS.pdf>
- sbsigntool `sbverify.c`: <https://git.kernel.org/pub/scm/linux/kernel/git/jejb/sbsigntools.git/plain/src/sbverify.c?h=v0.9.5>
- sbsigntool `sbsign.c`: <https://git.kernel.org/pub/scm/linux/kernel/git/jejb/sbsigntools.git/plain/src/sbsign.c?h=v0.9.5>
- sbctl `verify.go`: <https://github.com/Foxboron/sbctl/blob/0.18/cmd/sbctl/verify.go>
- sbctl `enroll-keys.go`: <https://github.com/Foxboron/sbctl/blob/0.18/cmd/sbctl/enroll-keys.go>
- sbctl FAQ, Option ROM: <https://github.com/Foxboron/sbctl/wiki/FAQ>
- nixpkgs `limine-install.py`: <https://github.com/NixOS/nixpkgs/blob/d5cc6833999746cffdfe0598f7bc801a57b887a9/nixos/modules/system/boot/loader/limine/limine-install.py>
- Microsoft, which key signs an update of KEK, `db` and `dbx` (section 1.3): <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-secure-boot-key-creation-and-management-guidance>
