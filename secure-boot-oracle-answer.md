## Recommendation

**Keep the factory keys, the existing appended certificate, and the unenrolled Limine design for this Windows anti-cheat goal—but fix the deployment and signing paths before treating it as reliable unattended infrastructure.** I would not migrate to lanzaboote or make every theme change re-enroll the configuration for this requirement.

The most consequential new finding is in **`deploy.sh`**: its `switch` operation activates with `test` and installs the bootloader afterward with `boot`. When deploying a generation that removes signing, this stops the old signing service **before** the unsigned loader is installed. The deployment can then succeed with **both Linux EFI copies unsigned**.

I reviewed the attachment, upstream sources, and the public repository at [commit `82945594`](https://github.com/OmerFarukOruc/nixos-config/tree/82945594fceb9f402450bc84493c712be8bdef34). Its `bootloader.nix` and `recovery.md` match the attachments. The attached upstream Limine files match nixpkgs revision `d4f25a3e562008648d45bcf2d70bcc7422cad84e`. This was a source review with an isolated signing-failure experiment; I did not deploy anything or test your physical firmware.

## Q1. Corrections and new findings

### 1. Finding 6: your ordering hypothesis is correct for a direct switch, but not for this repository’s deployment command

For a direct invocation of the target generation’s `switch-to-configuration switch`, the order is:

1. Run the target generation’s pre-switch checks.
2. Install its bootloader.
3. Stop outgoing systemd units.
4. Activate the target configuration.

At the matching nixpkgs revision, these are `src/main.rs:1829–1846`, `2192–2225`, and `2229` onward. The official NixOS description agrees. [GitHub](https://github.com/NixOS/nixpkgs/blob/master/nixos/doc/manual/development/what-happens-during-a-system-switch.chapter.md?utm_source=chatgpt.com)

Consequently, when switching directly from signing generation **A** to non-signing generation **B**, A’s active service can re-sign the files **after** B installs unsigned copies.

Two qualifications matter:

- The attached `docs/recovery.md:378–385` **already describes this repair**. Its opening sentence describes what the installer writes; the following sentences explain re-signing on service stop or shutdown.
- `ExecStop` requires the service to have started successfully. It also needs working key material, a writable ESP, and time to finish. It is a repair attempt, not a bootability guarantee. Systemd explicitly documents the successful-start prerequisite. [freedesktop.org](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html?utm_source=chatgpt.com)

**Your deployment script changes the answer.**

In [the inspected `deploy.sh`](https://github.com/OmerFarukOruc/nixos-config/blob/82945594fceb9f402450bc84493c712be8bdef34/deploy.sh):

- `activate():607–608` invokes `switch-to-configuration test`.
- `deploy():754–759` activates, stops the rollback timer, then installs boot entries.
- `install_entries():685–687` invokes `switch-to-configuration boot`.
- `install_entries():689–703` restores previous boot entries only if that command fails.

For A → B, where B removes signing:

| Operation | Result |
|---|---|
| B’s `test` activation | A’s signer stops and can sign the **existing** files. No bootloader has been installed yet. |
| B finishes activating | The signing service is absent. |
| Rollback timer stops | No activation rollback remains armed. |
| B’s `boot` installation | Both EFI copies are overwritten unsigned. |
| Installer returns zero | Deployment succeeds; no repair runs. |
| Subsequent shutdown | B has no signing service. |

**This is a concrete success-with-unbootable-Linux path.** The recovery guide must distinguish `./deploy.sh … switch` from a direct `switch-to-configuration switch`.

Do not reorder the whole deployment strategy just to exploit `ExecStop`. Add an explicit deployment guard and final verification.

### 2. Finding 5 is correct—and exposes a stale-output hole in your wrapper

**Sources:** `bootloader.nix:25–28, 73–90`; upstream `sbsign.c` v0.9.5.

Upstream v0.9.5 calls `image_write()` without checking its return value, then returns success. `image_write()` returns an error when opening the output fails. The matching nixpkgs package selects v0.9.5. This validates your finding, while distribution-patched builds may behave differently. [Git at Google](https://kernel.googlesource.com/pub/scm/linux/kernel/git/jejb/sbsigntools/%2B/refs/tags/v0.9.5/src/sbsign.c?utm_source=chatgpt.com)

Your subsequent `sbverify --cert` catches the ordinary case where no output exists. However, the installed-loader helper uses the reusable pathname:

```sh
sign-limine "$loader" "$loader.signed"
```

If a valid, older `"$loader.signed"` survives an interrupted attempt, and the next `sbsign` returns zero without replacing it:

1. `sbverify` verifies the old file.
2. `mv` publishes that old file as the primary.
3. The helper copies it over the fallback.
4. The helper returns zero.

I reproduced this **control flow using fault injection into the extracted helper bodies**:

| Injected condition | Outcome |
|---|---|
| Signer returns zero without output; output absent | Helper fails; previous fallback remains. |
| Same failure; valid stale output already present | Helper succeeds; both paths become the stale image. |

This was not a reproduction of a naturally occurring FAT failure on your desktop. It establishes the conditional acceptance bug.

**Fix:** create a unique staging directory on the ESP and sign to a previously nonexistent pathname inside it. Verify that candidate before publishing it. Never accept a reusable `.signed` file as evidence that the current invocation produced output.

### 3. A concurrent repair and installation can copy an unsigned primary over the fallback

**Sources:** `bootloader.nix:82–89`; `limine-install.py:691`.

The helper verifies the primary, then later reads the primary pathname again for comparison and copying. Nothing in this helper serializes those reads against an installer replacing that pathname.

A possible interleaving is:

1. Repair verifies signed primary A.
2. An installer replaces the primary with unsigned B.
3. Repair copies B to the fallback.
4. Repair returns success.

This does not mean two normal NixOS switches bypass their own serialization. The relevant exposure is an independently invoked `sign-installed-limine` overlapping an installation—for example, manual recovery while the automatic updater runs.

**Fix:** serialize the entire managed bootloader installation and standalone repair against one shared lock. Publish both destinations from the same staged, verified candidate.

The lock should cover **bootloader installation**, not the whole system switch: otherwise service stop/start can deadlock while trying to acquire a lock held by the switch waiting for that service.

### 4. Finding 7 is operationally more significant than “minor”

**Sources:** `bootloader.nix:45–57, 82–90, 157–158`.

The pre-switch checker checks certificate membership, but the independently callable signer and its boot/shutdown service do not.

A concrete failure sequence is:

1. `/var/lib/secure-boot/db.key` and `.pem` are replaced with a new, unenrolled pair.
2. The primary is unsigned following an interrupted or non-signing installation.
3. The service signs it with the new certificate.
4. Local verification succeeds.
5. The helper overwrites the previously trusted fallback with that newly signed image.
6. Firmware rejects both copies.

The old generation’s executable still reads the **current mutable key files**. Retaining the old script does not retain the old key.

Merely adding another signature to an already signed image does not necessarily remove its previous trusted signature. The unsigned-primary condition above is what makes this failure sequence unambiguous.

**Fix:** apply the common trust guard before every modifying entry point, including manual repair and service execution.

Also distinguish “firmware reports Secure Boot off” from “the variable could not be read.” The conditional at `bootloader.nix:50–57` currently skips membership checking when the variable is missing or its read does not produce the expected value. On a live UEFI host, an unreadable or malformed state should fail before modification.

Finally, **`sbverify --cert` plus certificate presence in `db` is still not a complete firmware acceptance test**: it does not reproduce `dbx` rejection or every firmware policy.

### 5. Installation failures can leave an unsigned primary and remove its NVRAM entry

**Sources:** `limine-install.py:683–691, 767–849`; `limine.nix:504–508`.

The installer:

1. Copies the raw Limine image to the primary path.
2. Performs EFI boot-entry operations.
3. Returns to the shell wrapper.
4. Runs your signing hook.

Therefore, an `efibootmgr` failure can prevent the hook from running after the primary has already become unsigned.

There is a second exposure: `limine-install.py:804–832` deletes an existing Limine boot entry before recreating it. Failure during recreation can leave the primary unsigned **and** remove its normal NVRAM entry.

This path is **reported as an installation failure**, so it should not be grouped with the silent-success defects above. The existing recovery guide already acknowledges it at `docs/recovery.md:354–360`.

The surviving fallback is conditional:

- It must already exist and be trusted.
- Firmware must offer or discover it.
- The installation must be one that preserves it.
- Its shared configuration and boot files must remain usable.

Also, `lib.mkBefore` at `bootloader.nix:147` orders your command before other **extra install commands**. It does not move signing before the Python installer’s raw copy.

### 6. The fallback is the latest signed duplicate, not an independent known-good recovery system

**Sources:** `bootloader.nix:86–90`; `limine-install.py:642–654, 887–890`.

Every successful repair immediately refreshes the fallback from the primary. Thus a correctly signed but broken Limine upgrade replaces both copies. Both also depend on the same configuration and kernel/initrd files.

The fallback usefully protects against an unsigned primary left by some interrupted installations. It does not provide independent protection against:

- A Limine regression.
- A broken shared configuration.
- Missing shared boot files.
- ESP corruption.
- Every power-loss point in a multi-file update.

The unconditional error message at `bootloader.nix:80`—that the fallback keeps the last signed copy—is too strong. It can be absent, invalid, or already updated.

For this project, I would document and test those limits rather than build a second boot-management system. Keep an external recovery path and verify the firmware’s actual fallback entry.

### 7. There is a missing enrollment invariant—and the current theme code qualifies your premise

**Sources:** `bootloader.nix:122–131`; `limine.nix:193–195`; [current `theme-root.nix`](https://github.com/OmerFarukOruc/nixos-config/blob/82945594fceb9f402450bc84493c712be8bdef34/nixosModules/theme-root.nix):21, 211–216, 273.

Your module asserts:

```nix
!limine.secureBoot.enable
```

It does **not** assert:

```nix
!limine.enrollConfig
```

The latter is independently configurable and defaults from `panicOnChecksumMismatch`. A future change to checksum policy can therefore change the promised unenrolled design without violating your assertion.

However, the current theme module already contains:

```nix
limine = cfg.bootloader == "limine" && !config.boot.loader.limine.enrollConfig;
```

Its Limine recoloring hook is gated on that condition.

Therefore, enabling native enrollment does **not automatically mean the new theme helper corrupts the configuration after every install**. It disables runtime Limine recoloring. An older helper or a separate manual writer can still invalidate an enrolled configuration, but that is a different claim.

Your concern about recovery is correct: in Limine 12.9.4, [`common/lib/config.c:488–511`](https://github.com/Limine-Bootloader/Limine/blob/v12.9.4/common/lib/config.c) checks an enrolled config hash without conditioning that check on firmware Secure Boot being enabled. Turning Secure Boot off does not bypass a mismatched enrolled hash.

**Fix:** explicitly preserve the intended `enrollConfig = false` policy and assert it. Also assert that this custom mode selects Limine on the supported x86-64 EFI architecture; the paths hardcode `BOOTX64.EFI`.

### 8. Finding 2 is correct, but add unchecked `enroll-config`

**Sources:** attached `limine-install.py:693–731, 752–760`; `limine.nix:243–251, 580–588`.

The unchecked subprocess list includes:

- `limine enroll-config`
- `sbctl create-keys`
- `sbctl enroll-keys`
- `sbctl sign` for the primary Limine image

The surrounding `try/except` catches launch exceptions, not a child returning a nonzero exit status.

The enrollment case has a particularly relevant consequence: if `enroll-config` returns nonzero while leaving an unenrolled image, subsequent signing can succeed, producing a signed image without the requested configuration enforcement.

Your observation about auto-enrollment is also correct: it is nested inside the “keys directory does not exist and auto-generation is enabled” branch. Existing keys do not trigger another automatic enrollment attempt.

Two fair qualifications to the Reddit criticism:

- `autoEnrollKeys.enable` enables `autoGenerateKeys` in the attached module. The short recipe is not missing that setting.
- Additional-file signing at line 754 **does** use `check=True`; not all signing calls are unchecked.

The short native configuration is a valid starting point for a clean supported setup. It does not resolve this repository’s runtime theme requirement, failure handling, or recovery procedure.

### 9. Finding 1 is substantially right; narrow “equivalent” and distinguish Setup Mode from clearing everything

For **`sbctl enroll-keys --microsoft`**, without `--append`, your account is correct:

| Variable | Result in sbctl 0.18 |
|---|---|
| PK | Locally generated sbctl PK |
| KEK | Local KEK plus Microsoft 2011 and 2023 KEKs |
| db | Local certificate plus the five bundled Microsoft certificates |
| dbx | Not written by that command |

Sources: [`enroll-keys.go:110–161`](https://github.com/Foxboron/sbctl/blob/0.18/cmd/sbctl/enroll-keys.go) and [`siglist.go:50–60`](https://github.com/Foxboron/sbctl/blob/0.18/siglist.go).

Qualifications:

- Plain `enroll-keys` does not inherently include Microsoft certificates; that description requires `--microsoft` or equivalent configuration.
- `--firmware-builtin` reads default databases, not an exact snapshot of the currently installed databases.
- Full enrollment still requires Setup Mode with `--append`; it is not a way to authenticate a write under MSI’s existing PK.
- **Entering Setup Mode need only remove PK.** Clearing every database is a separate operation that can discard `dbx`. Lanzaboote’s own guide explicitly warns against clearing all keys for that reason. [nix-community.github.io](https://nix-community.github.io/lanzaboote/getting-started/enable-secure-boot.html?utm_source=chatgpt.com)

“For Windows trust it is equivalent” is reasonable when scoped to trusting the relevant Windows boot images with the same revocations. It does not establish equivalent firmware servicing or anti-cheat policy.

Windows image verification does not inherently require MSI’s PK. Keeping that PK preserves the OEM authorization relationship for future **KEK updates**. Ordinary authenticated `db`/`dbx` updates use an enrolled KEK or PK; Microsoft explicitly documents DB updates succeeding while a required OEM PK-signed KEK update fails. [UEFI Specification 2.10 documentation](https://uefi.org/specs/UEFI/2.10/32_Secure_Boot_and_Driver_Signing.html?highlight=efi_authentication_info_protocol\&utm_source=chatgpt.com)

Your machine already has the 2023 KEK. This is an ownership and future-maintenance distinction, not evidence of an immediate update problem.

### 10. Finding 3: “cannot brick” is too categorical; describe soft-bricking accurately

The sbctl maintainer documents loss of graphics and firmware access when an Option ROM is no longer trusted. It calls this **soft bricking** and notes that Option ROMs can belong to graphics, storage, and other PCI devices. [GitHub](https://github.com/Foxboron/sbctl/wiki/FAQ?utm_source=chatgpt.com)

Your argument should be:

> Removing required trust can prevent hardware initialization and make recovery difficult.

It should not claim that appending this certificate is known to permanently destroy this MSI board.

Keeping the existing factory trust avoids the particular trust-removal mechanism being discussed. The iGPU offers another potential display path, but it should be tested before being described as guaranteed recovery.

Also, sbctl’s TPM event-log check is conditional; `--microsoft` and `--append` bypass that check in 0.18. It is a precaution, not proof that every device will initialize.

### 11. Finding 4: the documentation corrections are justified, with a few additions

| Location | Recommended correction |
|---|---|
| Playbook `121–122` | “`sbctl verify` can print **not signed** while exiting zero.” It does not print success for the unsigned file. [`verify.go:69–77`](https://github.com/Foxboron/sbctl/blob/0.18/cmd/sbctl/verify.go) confirms this. |
| Playbook `89`; install guide `185–187` | Replace the broad vendor-PK requirement with the narrower OEM KEK-servicing explanation. |
| Playbook `89` | Delete the unsupported anti-cheat/custom-key assertion. The cited Activision report discusses attestation failures, not a custom-key prohibition. [support.activision.com](https://support.activision.com/tpm-report?utm_source=chatgpt.com) |
| Playbook `237–240` | Say Limine provides no authenticated config-to-kernel chain here. It still checks configured file hashes, with the configured nonfatal mismatch policy. |
| Playbook opening | State the limited Linux trust boundary before the procedure. |
| Playbook `43, 183, 225` | A `dbx` hash count or size is not proof of unchanged contents. Compare exports/fingerprints of actual entries; distinguish “unchanged by our operation” from “equal to factory defaults.” |
| Playbook `203–209` | Disabling Secure Boot removes signature-policy rejection; it does not restore corrupted files. Qualify CMOS-reset behavior with board-specific evidence. |
| Recovery `354–385` | Describe service repair as conditional, and add the deploy-script ordering case. |

Limine’s upstream documentation supports your central security conclusion: an unenrolled image can boot under firmware Secure Boot but does not enable Limine’s authenticated configuration enforcement. [GitHub](https://github.com/Limine-Bootloader/Limine/blob/v12.x/USAGE.md?utm_source=chatgpt.com)

The extra 700 bytes in `dbx` establish a difference from the default. Size alone does not identify the writer or establish that the revocation database is current.

## Q2. Design decision and trade-offs

### Keep the current trust policy, with explicit limits

For your stated requirements, I recommend:

- Keep MSI PK and the existing KEK, db, and dbx contents.
- Keep the certificate already appended to db.
- Keep Limine without config enrollment.
- Keep Windows boot through `efi_boot_entry`.
- Fix the installation/deployment reliability defects.
- Treat boot/shutdown re-signing as supplementary repair.

`efi_boot_entry` really does set `BootNext` and request a warm reset, as shown in [`efi_boot_entry.c:129–142`](https://github.com/Limine-Bootloader/Limine/blob/v12.9.4/common/protos/efi_boot_entry.c). That fits your desired Windows path. The game result remains scoped to the configuration and game you actually tested.

### Comparison

| Option | Benefit | Cost in this setup | Decision |
|---|---|---|---|
| **Current unenrolled Limine, repaired** | Preserves runtime boot-menu colors, current keys, and familiar recovery | Custom signing code remains; Linux boot inputs are unauthenticated | **Recommended for this goal** |
| **Native Limine Secure Boot + sbctl** | Uses the native integration and authenticates the configuration and boot files | Current theme module disables Limine recoloring; unchecked subprocess failures need addressing; config mismatch survives SB-off | Best next choice if authenticated Linux boot becomes a requirement and static boot-menu colors are acceptable |
| **Lanzaboote** | Integrates a signed boot chain protecting kernel, initrd, and command-line components | Loader/menu migration and recovery work; does not preserve the Limine theme workflow | Unnecessary migration for the present goal |
| **Custom enrollment after every theme edit** | Keeps changing colors while authenticating the configuration | Each color change becomes a coordinated config-and-EFI update, with mismatch windows and more recovery cases | **Do not choose this** |

Lanzaboote uses systemd-boot and protects the later boot components through its signed stub and verification scheme. Those are useful capabilities for a Linux boot-integrity project. [nix-community.github.io](https://nix-community.github.io/lanzaboote/?utm_source=chatgpt.com)

**Firmware ownership and signing-tool choice are separate decisions.** Neither sbctl signing nor lanzaboote inherently requires replacing MSI’s PK. Current lanzaboote exposes separate public/private key paths, so it can reuse your already enrolled db certificate with automatic enrollment disabled. See [`lanzaboote.nix:124–137`](https://github.com/nix-community/lanzaboote/blob/master/nix/modules/lanzaboote.nix).

### How the unencrypted root affects the decision

An unencrypted root does not make authenticated boot inherently worthless: authenticating the kernel and initrd still protects a meaningful boundary.

But this host also keeps the signing private key on that unencrypted filesystem. An offline attacker can access the key or change userspace. Simply enabling config enrollment would therefore not produce a complete defense against offline tampering.

For the present compatibility goal, accepting that limitation is reasonable. Put it near the beginning of the guide:

> This setup enables firmware Secure Boot and permits Windows to boot through its Microsoft-signed path. It does not authenticate the NixOS configuration, kernel, initrd, or root filesystem against malicious modification.

The principal reason to keep factory keys is minimizing changes to a working trust and servicing configuration. There is no need to support that choice with an unproven claim that Windows or the game requires MSI’s PK.

## Q3. Ordered implementation plan

### A. Documentation-only changes

#### 1. Correct the playbook’s purpose, claims, and evidence

**File:** `docs/secure-boot-playbook.md`

Move the scope statement above the procedure. Correct the `sbctl verify`, PK servicing, hash-checking, anti-cheat, and `dbx` statements identified above.

Separate observations from guarantees. Preserve the actual game test, board, firmware, and date. Describe the fallback as a signed duplicate with shared dependencies.

For future enrollment procedures, record PK, KEK, db, and dbx contents before and after the change. Key counts remain useful diagnostics, but not proof of preservation.

**Verify:** review every claim against the named source or recorded machine observation. Ensure the guide promises signature-policy rollback only where that is what disabling Secure Boot provides.

**Rollback:** revert this documentation change. No runtime or firmware effects.

#### 2. Correct recovery instructions for all three activation routes

**Files:** `docs/recovery.md`, `docs/install-nixos-desktop.md`

Add a small operation table:

| Route to a non-signing generation | Expected current behavior |
|---|---|
| Direct `switch-to-configuration switch` | Old active service can repair after installation. |
| `switch-to-configuration boot` | Repair is deferred to manual execution or the old system’s clean shutdown. |
| `./deploy.sh … switch` | Old service stops before installation; later unsigned files are not repaired. |

Require verification after any operation involving an old non-signing generation. Make clear that choosing an older kernel from an existing signed Limine menu differs from reinstalling that generation’s historical bootloader configuration.

**Verify:** trace the table against the pinned activation and deployment sources.

**Rollback:** documentation revert.

### B. Code changes

#### 3. Make the custom policy explicit and share its preflight checks

**Files:** `nixosModules/bootloader.nix`, `machines/schema.nix`

Add explicit configuration and assertions for the supported mode:

- Limine selected.
- Supported x86-64 EFI path.
- Non-removable installation.
- Native Limine Secure Boot disabled.
- Config enrollment disabled.

Update the schema description to describe the actual trust boundary.

Factor the runtime checks so installation, manual signing, and service signing all use them. Check:

- The expected ESP is mounted.
- The key and certificate can produce a verifiable candidate.
- Firmware state is readable in the live UEFI environment.
- When enforcement is active, the certificate is present in db.

Provide a clearly documented offline/recovery path if missing efivars must be supported. Do not silently treat an unreadable live variable as Secure Boot being disabled.

Allow the explicit preflight to run before the deploy script’s `test` activation. Currently the `switch | boot` case at lines 141–144 makes a generic `check` invocation insufficient.

**Verify:** evaluate all hosts; test incompatible option combinations and missing/mismatched keys in isolation. Confirm rejected checks leave the test ESP unchanged.

**Rollback:** deploy the preceding signing-capable generation. No key enrollment changes.

#### 4. Replace reusable signing outputs and serialize managed writes

**File:** `nixosModules/bootloader.nix`

Use a unique staging directory on the ESP with cleanup on exit. Sign or copy a stable input into a fresh candidate, verify it, and publish primary and fallback from those verified bytes.

Keep the existing fallback untouched until its replacement is prepared and verified. Change the failure message to report what was actually preserved rather than promise a valid fallback.

Wrap the managed bootloader installation and standalone repair with the same lock. Avoid recursive acquisition when the installer calls the signer, and release it before systemd unit transitions.

Keep preflight at the installation boundary as well as the system-switch boundary, so direct invocation of the installer receives protection.

The current post-install architecture still has a window where the upstream installer has published an unsigned primary. For this scope, I would retain that architecture with a verified existing fallback and accurate failure reporting. Eliminating that window requires staging/signing before upstream publication—a separate installer change, not a rearrangement of `extraInstallCommands`.

**Verify:** fault-inject zero-with-no-output, stale temporary files, failed writes, failed renames, and overlapping installer/repair execution. Confirm no successful operation publishes unverified bytes and failed fallback publication preserves its previous bytes.

**Rollback:** restore the previous module and redeploy a signing-capable generation. Retain the same enrolled key.

#### 5. Fix deployment before and after activation

**File:** `deploy.sh`

Before `activate_with_rollback`:

- Read the target’s actual Secure Boot state.
- For this host’s signing arrangement, reject a candidate that removes signing support while enforcement remains active.
- Run the candidate’s signing preflight before its service can start or replace anything.

This guard must live outside the incoming generation alone: a historical non-signing generation contains no guard.

After bootloader installation, before promotion/success:

- Verify both on-disk EFI images with the intended certificate.
- Verify the common trust prerequisites.
- Require the expected fallback relationship.
- Treat failure as a boot-install failure and use the existing restoration path; verify that restoration too.

Preserve the current `test`-then-`boot` deployment strategy. Make its bootability checks explicit.

For an intentional migration away from this signing arrangement, require a prepared alternative boot path or Secure Boot disabled by the owner.

**Verify:** extend the deployment VM test with signing A → non-signing B. The acceptable outcome under enforced Secure Boot is rejection **before activation**, with the original EFI files unchanged. Also test that a failed final verification cannot promote the release.

**Rollback:** revert the deployment-script change from a working signing generation. This changes no firmware keys.

#### 6. Execute targeted tests that cover these failure modes

**Files:** existing `ci/deploy-script.nix`; new `ci/limine-signing.nix`; `flake.nix`; `ci/checks.sh`

Use disposable keys and a disposable FAT filesystem for signing/publication tests. Extend the existing deployment VM fixture for the lifecycle transition.

The minimum meaningful cases are:

| Case | Required result |
|---|---|
| Missing or mismatched key | Failure before ESP mutation |
| Signer exits zero without output | Failure |
| Valid stale `.signed` file exists | It cannot become the accepted output |
| New unenrolled key, unsigned primary, trusted fallback | Refuse modification under enforcement |
| Concurrent installer and repair | Serialized publication |
| EFI-entry creation fails after raw copy | Nonzero result; accurately reported fallback state |
| Deploy removes signing while SB is active | Rejected before `test` activation |
| Final EFI verification fails | No successful release promotion |
| Unenrolled Limine config colors change | Normal boot still works |
| Supported rollback | Final EFI state verified explicitly |

An OVMF boot test with the actual Limine package adds useful protection against a future Limine release changing unenrolled behavior. Perform destructive negative tests there, not on the desktop.

Run `nix fmt`, `ci/gate.sh`, the affected package builds, and **explicitly build the relevant test derivations**. In the inspected repository, `ci/checks.sh:232–239` checks that VM-test output names exist; it does not execute those VM tests. Registration alone is insufficient.

**Rollback:** revert the test wiring if necessary; tests should never write the physical machine’s firmware.

### C. Attended rollout and recovery verification

#### 7. Record the baseline, deploy, then test the actual boot paths

**Files:** no new implementation files; update the “What was tested” record afterward.

Before rollout, retain a known working signing generation and copies of the current signed EFI files and configuration. Record the ESP mount, boot entries, certificate fingerprint, firmware databases, and service state. Pause automatic upgrades during the attended validation window.

Deploy the repaired implementation and verify:

```sh
sudo sbverify --cert /var/lib/secure-boot/db.pem \
  /boot/efi/limine/BOOTX64.EFI

sudo sbverify --cert /var/lib/secure-boot/db.pem \
  /boot/efi/boot/BOOTX64.EFI

sudo cmp /boot/efi/limine/BOOTX64.EFI \
  /boot/efi/boot/BOOTX64.EFI
```

Then, with the owner present:

1. Boot NixOS through the normal Limine entry.
2. Boot through the independently selected fallback entry.
3. Change the theme and confirm another normal boot.
4. Start Windows through Limine’s Windows entry.
5. Confirm Windows Secure Boot status and run the previously tested game.

Check that PK, KEK, db, and dbx did not change as part of the deployment. Restore the updater after verification.

**Rollback:** use the retained signing generation. If firmware rejects both Linux entries, disable Secure Boot and repair the EFI files from Linux or recovery media; Windows remains the separate boot entry described in your existing recovery procedure. Do not reset the key databases as the first recovery action.

**No firmware key write is needed for this recommended change set.** The owner’s keyboard presence is needed for boot-path testing and, only if recovery requires it, changing the Secure Boot setting.
