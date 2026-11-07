# agents

This folder holds the configuration of Omer's agent CLIs: Claude Code, Codex and the others. `home-manager/modules/agents.nix`, which `nixosModules/agents.nix` imports on nixos-desktop, nixos-rog and devbox, keeps a main checkout of this repository current on each of them, so the CLIs can read this folder from it.

## Edit loop

- Edit `agents/` in the main checkout (`~/Desktop/workspace/nixos-config`, the option `oruc.agents.checkout`), commit to `main` there, then run `git pull --rebase` and `git push origin main`. Every other path of this repository still needs a worktree. The pull unit below sets `git config agents.mainCheckoutEditPaths agents/` in the checkout, and Claude Code's edit guard allows the main checkout only for those paths.
- A main checkout needs `direnv allow` once, so the commit hooks find their config.
- `agents-pull.timer` runs `agents-pull` every hour. It clones the checkout when the folder is missing and otherwise runs `git pull --ff-only` on `main`. A failed run leaves a line that each new shell prints until a run succeeds (`home-manager/modules/scheduled-unit.nix`); `journalctl --user -t agents-pull` shows the run. An unreachable GitHub is not a failure.

## Checks

The pre-push gate (`ci/gate.sh`) checks every commit between `origin/main` and the pushed revision:

- `ci/private-scan.sh` runs on every push. It runs `gitleaks git` on those commits and refuses one whose message or added lines, binary files and merge results included, hold one of Omer's private values, such as an account email, an Infisical project ID or the tailnet name. This repository is public and keeps every pushed commit, so a value has to be gone from the commit itself, not only from a later one. The values come from the sops secret `agents-private-values` in `secrets/agents.yaml`, one per line, decrypted to `/run/secrets/agents-private-values` on nixos-desktop, nixos-rog and devbox; `AGENTS_PRIVATE_VALUES` names another file. The scan prints the commit and the file of a hit, never the value. Add a value with `sops secrets/agents.yaml` ([Secrets](../docs/architecture.md#secrets)).
- `ci/agents-checks.sh` runs when those commits touch `agents/`. It runs shellcheck on each `.sh` file and ruff on each `.py` file, and parses each `.json` and `.toml` file, as the pushed revision holds them.
- When every path those commits touch is under `agents/`, the gate skips the Nix checks.
