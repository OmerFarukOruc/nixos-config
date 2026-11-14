# Plan: Secure Boot review fixes for nixos-desktop

Session record for the branch `fix/secure-boot-review`. Delete this file and
`secure-boot-oracle-answer.md` in the last commit before landing on `main`.

## Hard constraints

- No firmware key writes. PK, KEK, `db` and `dbx` stay as they are; the
  appended "nixos-desktop Secure Boot" certificate stays.
- Never read or print `/var/lib/secure-boot/db.key`.
- Post nothing to Reddit or GitHub issues without Omer.
- Nix work runs on the host the session runs on (AGENTS.md, Checks).
- `deploy.sh` and `ci/` changes need a review of the final diff by an agent
  that did not write them, and `deploy.sh` needs the `deploy-script` VM check
  plus `./deploy.sh nixos-rog test` (AGENTS.md, Checks).
- Boot-path tests on nixos-desktop need Omer at its keyboard.

## Decision

Keep the design: factory keys plus one appended `db` certificate, Limine
signed with `sbsign`, no enrolled `limine.conf`, Windows through
`efi_boot_entry`. The goal is Windows anti-cheat only. Root is unencrypted
and the signing key lives on it, so config enrollment would add little, and
an enrolled hash is checked even with Secure Boot off (Limine v12.9.4
`common/lib/config.c:488-511`), which loses the one-switch rollback.
Switching to `boot.loader.limine.secureBoot` + sbctl is the next step only if
authenticated Linux boot becomes a goal; it would cost the runtime Limine
recolour (`nixosModules/theme-root.nix:21` already turns it off when
`enrollConfig` is on) and the PK ownership. Lanzaboote is not worth the
migration for this goal.

## Evidence already checked (session 0a62c7a1 on nixos-desktop)

- Firmware: PK "MSI SHIP PK" equals PKDefault; KEK (Microsoft 2011, Microsoft
  2023, MSI) equals KEKDefault; `db` = 5 Microsoft + MSI SHIP DB + ours; `dbx`
  700 bytes larger than `dbxDefault`, fwupd "UEFI dbx: Update State: Success".
- Both ESP copies pass `sbverify --cert` and are identical.
- `sbsign` 0.9.5 exits 0 when it cannot open its output (run with a throwaway
  key; `sbsign.c:297` ignores `image_write`).
- `sbctl verify` 0.18 prints "is not signed" and exits 0 (`verify.go:70-77`).
- `switch-to-configuration-ng` installs the boot loader (`main.rs:1844`)
  before it stops units (`:1886`).
- `deploy.sh switch` runs `switch-to-configuration test` (`deploy.sh:624`,
  `:755`) and only then `boot` (`:687`, `:759`). Deploying a generation
  without signing therefore stops `limine-signature` before the unsigned
  install, and nothing signs again. Confirmed by reading; not run.
- nixpkgs `limine-install.py` runs `sbctl sign`, `create-keys`,
  `enroll-keys` and `limine enroll-config` without checking exit codes
  (lines 697, 711, 720, 728).

## Steps

Each step lists files, size (guess), verification, rollback.

### 1. Docs (no runtime effect)

Files: `docs/secure-boot-playbook.md`, `docs/install-nixos-desktop.md`
(Secure Boot), `docs/recovery.md` (Secure Boot), `docs/architecture.md`
(Inventory, Limine paragraphs), `machines/schema.nix:95` description.
Size: about 60 changed lines (guess).

- Playbook opening: state the trust boundary first. Secure Boot covers the
  firmware to Limine; the config, kernel, initrd and root are not
  authenticated; the Microsoft third-party CAs in `db` let any shim-signed
  medium boot.
- Playbook:89 and install guide:185: the vendor PK matters for future KEK
  updates only; `db`/`dbx` updates are signed by Microsoft's KEK. Drop "anti-
  cheat reports mention custom key sets" (no source). Add the real reasons:
  no Setup Mode, `dbx` updates kept, fewest firmware changes.
- Playbook:121-122: "`sbctl verify` prints not signed and still exits 0".
- Playbook:237-240: Limine still checks the kernel hashes from the
  unauthenticated config and only warns on a mismatch.
- Playbook steps 1 and 7: compare `dbx` and the key lists by content
  (`efi-readvar` output or a hash of the variable without its 4-byte
  attribute prefix), not by hash count.
- Playbook Rollback: disabling Secure Boot lifts signature checks; it does not
  repair files. CMOS clear behaviour is board-specific.
- New playbook section "Why not sbctl or `boot.loader.limine.secureBoot`":
  the comparison table (PK/KEK/db/dbx, Setup Mode, config hash, runtime theme,
  unchecked `sbctl` calls upstream), and the option ROM soft-brick risk as the
  reason to keep Microsoft's UEFI CAs on any route.
- Recovery: a table of the three routes to a generation without signing:
  direct `switch` (old service signs again at stop), `boot` (signs at the
  next clean shutdown), `./deploy.sh … switch` (nothing signs; both copies
  unsigned) until step 4 lands.
- Fallback wording everywhere: it is the last signed duplicate and shares the
  config and kernels; it does not survive a broken Limine release.

Verify: each changed claim against its cited source; `nix fmt`.
Rollback: revert the commit.

### 2. `bootloader.nix`: assertions and the trust check on every path

Size: about 30 changed lines (guess), no new dependency, no upkeep beyond the
module.

- Assert `!limine.enrollConfig` next to `!limine.secureBoot.enable`, and that
  the host is x86_64 (the paths are `BOOTX64.EFI`).
- Move the `db` membership check into one function that `check-limine-
  signing-key` and `sign-installed-limine` both run, so the boot/shutdown
  service and a manual run never sign with a certificate the firmware lacks
  while it enforces Secure Boot.
- Fail closed when `/sys/firmware/efi` exists but the `SecureBoot` variable
  cannot be read; skip the check only when there are no efivars at all
  (installer chroot booted with Secure Boot off).

Verify: `scripts/eval.sh` that nixos-desktop still evaluates; `ci/gate.sh`;
on nixos-desktop after deploy, `sudo sign-installed-limine` exits 0 and
changes nothing; with a scratch copy of the script pointed at a throwaway
cert, the db check refuses.
Rollback: deploy the previous generation; both copies stay signed.

### 3. `bootloader.nix`: sign and publish from one verified candidate

Size: about 25 changed lines (guess).

- Sign into a fresh `mktemp` file in the loader's folder on the ESP, never a
  reused `$loader.signed`, so an old file cannot pass as new output.
- When the primary already verifies, copy it to a fresh temp file and verify
  that copy. Publish primary (when re-signed) and fallback from the verified
  temp file, so a primary replaced mid-run is never copied to the fallback.
- Remove temp files on exit. Reword the ERR message to say what was kept,
  without promising a valid fallback.

Verify by runs, not new CI tests: copy the built script with paths pointed
at a scratch folder and throwaway key, then inject (a) an `sbsign` stub that
exits 0 and writes nothing, (b) a valid stale temp file, (c) a primary
swapped between verify and copy. Each must fail or publish only verified
bytes. Then the live check on nixos-desktop as in step 2.
Rollback: deploy the previous generation.

### 4. `deploy.sh`: refuse a deploy that drops signing (optional, recommended)

Size: about 15 lines (guess) plus a `deploy-script` VM case; needs the
review, the VM check and `./deploy.sh nixos-rog test`.

- Before `activate_with_rollback`, when the target's `SecureBoot` variable
  reads 1 and its current system has `sw/bin/sign-installed-limine`, refuse a
  candidate that lacks it, with a message that names turning Secure Boot off
  first.
- After `install_boot_entries`, on such a host, run `sbverify --cert` on both
  copies before `promote_release`; on failure, take the existing restore path.

Skip this step if Omer prefers documenting the case (step 1) over code.
Rollback: revert; no firmware effect.

### 5. Land and deploy

From the branch worktree: delete this file and the Oracle answer, `nix fmt`,
`ci/gate.sh`, start the `code-reviewer` agent on the final diff, fix every
finding, rebase on `origin/main`, push `HEAD:main`
(AGENTS.md). Then `./deploy.sh nixos-desktop switch`.

### 6. Attended checks on nixos-desktop (Omer at the keyboard)

1. `sudo sbverify --cert /var/lib/secure-boot/db.pem` on
   `/boot/efi/limine/BOOTX64.EFI` and `/boot/efi/boot/BOOTX64.EFI`, and `cmp`
   of the two: both OK and equal.
2. Reboot: Limine menu, NixOS boots; `bootctl status` shows
   `Secure Boot: enabled (user)`.
3. F11 > "UEFI OS" (the fallback): same menu, NixOS boots.
4. Run `theme` with another scheme, reboot: boots.
5. Windows from the Limine entry: `Confirm-SecureBootUEFI` prints True, the
   game starts.
6. `efi-readvar` PK/KEK/db/dbx content unchanged from the evidence above.

Rollback: boot the previous generation from the Limine menu; if the firmware
refuses both copies, set Secure Boot to Disabled and run
`sudo sign-installed-limine`. Never reset the key databases first.

## Open

- [ ] Omer: keep step 4 (`deploy.sh` guard) or document the case only.
- [ ] Old worktree `worktrees/nixos-config/feat-secure-boot` (branch
  `feat/secure-boot`, commit ead6c93, session 3bb3fd33) is an earlier draft of
  what landed as c7fbb13; remove it with Omer's approval.
