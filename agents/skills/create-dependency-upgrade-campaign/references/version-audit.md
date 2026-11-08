# Version Audit Reference

Read this file during Phase 2 and Phase 3.

## Contents

- [Ledger schema](#ledger-schema)
- [Discovery pass](#discovery-pass)
- [Source hierarchy](#source-hierarchy)
- [Stability rules](#stability-rules)
- [Exact-coordinate rules](#exact-coordinate-rules)
- [Compatibility conflicts](#compatibility-conflicts)
- [Campaign matrix checks](#campaign-matrix-checks)

## Ledger schema

Create one row for every direct version surface inside the approved scope.

| Field | Required content |
|---|---|
| Surface | Backend, frontend, CI, release, image, runner, gateway, cache, or another repository surface |
| Component | Canonical project or artifact name |
| Owner file | Exact repository file or generated source of truth |
| Current | Exact version, tag, commit, digest, checksum, range, or platform owner |
| Latest stable | Newest non-preview release from a primary source |
| Latest LTS | Newest supported LTS release when the component has LTS lines |
| Candidate | Proposed exact campaign target |
| Compatibility | Supported ranges and known migration edges |
| Acquisition | Registry coordinate, action commit, binary URL, or package coordinate |
| Integrity | Commit SHA, checksum, or OCI digest when applicable |
| Action | Upgrade, keep, remove, replace, platform-manage, or investigate |
| Evidence | Primary source and observed repository proof |

The ledger is exhaustive when every in-scope direct version expression has one row or an explicit platform owner.

## Discovery pass

Use `rg` and ecosystem tools before web research.

Inspect these surfaces when present and included:

- Package manifests and lockfiles.
- Gradle, Maven, npm, pnpm, Yarn, Cargo, Go, Python, Ruby, and .NET configuration.
- Plugin versions and platform BOMs.
- Language toolchains and compiler targets.
- Wrappers and distribution checksums.
- Dockerfiles, Compose files, Helm charts, and image digests.
- GitHub Actions and other CI actions.
- Self-hosted runner images and bundled tools.
- Deployment scripts and runtime CLIs.
- Database, cache, gateway, proxy, and local-service images.
- Generated version files and repository audit scripts.
- Version comments that function as policy or evidence.

Read dependency graphs after reading declarations.

Separate these classes:

1. Direct repository-owned versions.
2. Platform-managed transitive versions.
3. Security or compatibility overrides.
4. Unused direct dependencies.
5. Abandoned direct dependencies.
6. Current components that need no change.

Do not create a ticket for a no-change row.

Assign removal or replacement work to the narrow slice that proves it.

## Source hierarchy

Prefer sources in this order:

1. Official release pages and support policies.
2. Official compatibility and migration documentation.
3. Official artifact repositories and registry metadata.
4. Official Git refs and release assets.
5. Installed dependency graph and build-tool output.

Use third-party indexes only to locate a primary source.

For technical claims, cite the primary source in the issue.

## Stability rules

Treat these labels as preview unless the owner explicitly includes them:

- Alpha.
- Beta.
- Milestone.
- Release candidate.
- Preview.
- Early access.
- Nightly.
- Snapshot.

Do not infer stability from version size.

Check the project's release policy.

For production runtimes, show both supported LTS and current stable releases.

Ask the owner when those choices differ.

For libraries and build tools, select the newest stable release after compatibility checks.

## Exact-coordinate rules

For GitHub Actions, resolve the approved tag to an executable full commit SHA.

Follow annotated tags to their commit object.

For build wrappers, record the official distribution checksum.

For downloaded binaries, record the exact asset name, URL, and official checksum.

For mutable container tags, record the observed OCI digest when rollback or supply-chain proof needs it.

For digest-pinned images, verify the target tag resolves to the planned digest.

For system packages, record the complete package coordinate.

When the package system cannot represent the target, design a checksum-pinned official acquisition path.

Verify that exact builder and runtime images contain the claimed runtime patch.

Do not infer a runtime patch from a major-only image tag.

## Compatibility conflicts

Build a compatibility graph before selecting targets.

Record minimum and maximum supported versions.

Check these common edges:

- Framework to language.
- Language plugin to build tool.
- Build tool to runtime.
- Framework to runtime.
- Test agent to runtime.
- CI action to runner.
- Client to daemon.
- Gateway or cache image to persisted data and rollback format.

When two selected latest releases conflict:

1. Verify the conflict from official sources.
2. Find supported distributions or acquisition paths.
3. Present the smallest owner decision.
4. Keep the recorded target unless the owner changes it.

Never silently downgrade.

## Campaign matrix checks

Before ticket design, require these statements to be true for the approved scope:

- Every row has an exact candidate or an explicit keep decision.
- Every candidate exists in its official distribution channel.
- Every breaking edge names the official migration source.
- Every integrity value is verified.
- Every transitive override has current evidence.
- Every unused dependency has a remove or keep decision.
- Every abandoned dependency has a replacement or accepted-risk decision.
- Every excluded surface is absent from proposed work.
