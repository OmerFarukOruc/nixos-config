# NixOS reference repositories

Use this loop when Omer supplies a repository to reuse while customizing this PC. The target repository remains the source of truth, and the reference repository remains evidence until Omer chooses a feature.

## Reference loop

1. **Clone.** Create a fresh temporary directory with `mktemp -d`, clone the reference repository there, and record its URL and exact `HEAD` commit. Keep the target repository unchanged. This step is complete when the clone and revision are recorded.
2. **Map.** Read the reference repository's agent instructions, README, `flake.nix`, `flake.lock`, NixOS host files, NixOS modules, Home Manager files, and any hardware, secret, or machine-specific integration. Group the reusable behavior into coherent feature groups. This step is complete when every relevant group has source paths, dependencies, portability limits, and a short behavior summary.
3. **Decide.** Present one feature group at a time. State its source paths, effect, dependencies, target paths in the current repository, portability limits, and validation command. Ask Omer whether to fold, leech, or skip that group. This step is complete only after Omer makes that decision.
4. **Adapt.** Apply only the approved decision. A fold may change the target architecture. A leech adapts the selected behavior to the current layout. Preserve the current deployment path, host identity, secrets boundary, and project rules unless Omer explicitly approves a change. This step is complete when the diff contains only approved feature work.
5. **Verify.** Run the narrowest relevant Nix parser, evaluator, formatter, or deployment check after the approved edit. Report observed results, changed files, and the next undecided feature group. This step is complete when the check result and any remaining blocker are recorded.

## Fold and leech

- **Fold** means adopting the reference repository's architecture. This can replace the current flake shape, host and module boundaries, Home Manager layout, input graph, and output conventions. It is a migration decision and needs explicit approval.
- **Leech** means adapting selected behavior from the reference repository into the current architecture. Keep the current flake, host layout, deployment script, and project rules. Treat this as the default for portable workstation and Home Manager features.

Portable features do not depend on the reference owner's hardware, hostnames, usernames, private paths, secrets, or service state. Mark those dependencies before asking for a decision. Copy configuration behavior, not private state.
