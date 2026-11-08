---
name: linear
description: Linear work from any repo through linctl. Use when reading a ticket or a project, writing a body or comment, changing state, or answering how Linear itself works.
---

# Linear

Every Linear operation goes through `linctl`. It reads the `.linctl.toml` of
the repo you run it from, and that pin is the only thing standing between a
wrong id and a stranger's project. A write that resolves anywhere else
hard-stops before it reaches Linear.

Some workspaces keep their pin in another repository, and their issues follow
write rules this public skill does not name. `/run/secrets/agents-linear-notes`
(sops, on nixos-desktop, nixos-rog and devbox) names those pins and rules; read
it before any call for a team the repo you are in does not pin. An untracked
copy of a pin in a checkout drifts unseen, so pass the tracked pin with
`--config <path>`.

A repo that tracks its own `.linctl.toml` uses it from the repo's root. For any
other target, run `linctl init --team KEY` inside a scratch directory, since
`init` writes to the current directory. Then pass `--config
<scratch>/.linctl.toml` on every call, and confirm the target with Omer before
any write.

## How to drive linctl

`linctl` ships its own skill, generated from the command tree with a CI drift
check, so it never goes stale:

```
~/Desktop/workspace/linctl/skills/linctl/SKILL.md
  references/commands.md         every command and flag
  references/guarded-writes.md   every command that changes Linear
  references/json-output.md      the stable shapes for parsing
```

When the host lacks it, clone KyaniteHQ/linctl there and check out the tag of
the installed binary (`linctl --version`, such as `v0.27.0`), so the skill
matches the commands you run. Read that for commands, flags, guarded-write
rules, and smoke tests. Per-domain
guidance also lives in the binary: `linctl issue usage`, `linctl <domain> --help`.

This file holds only what those cannot know.

`linctl files download` returns 401 on a private upload because it sends no
Authorization header.

A team's previous keys and the workspace's previous URL keys keep old issue
links and `linear.app/<old-key>` URLs redirecting. Neither linctl, the GraphQL
API, nor a settings page removes them (checked 22-10-2026); ask Linear support.

## The round trip

`issue export` is a report, not a source file. It wraps the body in a metadata
header and appends comment and attachment sections, so writing it straight back
buries the description inside a copy of its own metadata. Use export for the
attachment list and the comments overview. Read one body with `--json --fields`.

To read a project spec:

1. `linctl project export <project_id> <dir>`
2. Take only what sits between `## Content` and `## Attachments`.

To edit a ticket body:

1. `linctl issue get <KEY-123> --json --fields description,updated_at > read.json`,
   then `jq -r .description read.json > body.md`
2. Edit that file.
3. `linctl issue update <KEY-123> --description-file body.md --if-updated-at "$(jq -r .updated_at read.json)"`.
   A `CONFLICT` means someone changed the issue after your read. Read it again
   and merge your edit into the new body; replaying the write would erase theirs.
4. Run the same `issue get` again and grep for the change. The write reports
   success on the id alone, so the readback is what proves the body landed.

To edit a comment:

1. `linctl comment get <comment_id> --json --fields body | jq -r .body > comment.md`
2. Edit that file.
3. `linctl comment update <comment_id> --body-file comment.md`
4. Run the same `comment get` again and grep for the change.

Done when the readback shows the new text and none of the line you replaced.

Linear stores a bare domain as a link, even inside backticks, so `` `github.com` ``
reads back as `[github.com](<http://github.com>)`. Compare a readback with that
conversion allowed. A read right after `issue update --title` can still show
the old title; read once more before calling the write failed.

`issue get --json --fields description` needs linctl 0.25.0 or newer, and
`issue update --if-updated-at` needs 0.27.0 or newer. An error naming a missing
`description` field or an unknown flag means the binary is older. Install the
release build and check it against the published checksums:

```
cd "$(mktemp -d)" && \
  gh release download v0.27.0 --repo KyaniteHQ/linctl -p 'linctl_0.27.0_linux_amd64.tar.gz' -p 'checksums.txt' && \
  grep ' linctl_0.27.0_linux_amd64.tar.gz$' checksums.txt | sha256sum -c - && \
  tar -xzf linctl_0.27.0_linux_amd64.tar.gz && install -m 0755 linctl ~/.local/bin/linctl && linctl --version
```

## Linear's own documentation

The private repo OmerFarukOruc/linear-docs mirrors Linear's docs, developer
docs and changelog as Markdown, with their images and videos. It answers
questions about Linear the product, which no CLI flag does. Keep it at
`~/Desktop/workspace/linear-docs`, cloning it there when the host lacks it, and
run `git -C ~/Desktop/workspace/linear-docs pull` before you read it, because
its `refresh` workflow commits Linear's changes every Monday.

The page `https://linear.app/<section>/<slug>` is the file
`<section>/<slug>.md`. Grep the clone, or start from `INDEX.md`, which also
maps old URLs that redirect. When the last commit is older than the feature you
ask about, read the live page by adding `.md` to its URL; `FETCH-ERRORS.md`
lists the pages the last refresh could not fetch.

## Prose in a ticket

A Linear body is a durable artifact. It follows the voice rules in
`~/.claude/rules/voice.md`: short sentences, active voice, one meaning per
word, no em dashes and no unicode arrows.

Write the outcome and the evidence. A ticket body is read months later by
someone deciding whether a decision still holds, so record what was decided and
what proved it, never the conversation that got there.

A refresh brings a body up to date with main. It changes facts, not decisions.
When main leaves more than one workable fix, or the old body left a choice
open, write it as an open owner decision with its options, not as an
instruction. A review of a refresh checks that main forces each added
instruction, or that the body lists it as a decision.

- Bad: "Add `env UV_FROZEN=1` to `local-gate-tests`."
- Good: "Owner decision: should `local-gate-tests` also run frozen? The rule
  named only the static and security hooks."

## Write discipline

- One comment per issue per piece of work. Rewrite that comment at completion.
  Never post a running trail of progress comments.
- Create an issue only when Omer asks for one. Propose it as an option instead.
- Fold review process into the requirement it produced. Critic names, model
  versions, round ledgers, and session IDs never appear in a body or comment.
- Linear writes run from the main loop, never from a subagent, so a wrong id
  cannot land in a stranger's project.
- When a write reports nothing, inspect its exit status, safe error output,
  target, and `linctl auth status` before changing credentials. Follow the linctl
  skill's OAuth recovery procedure only when the evidence supports an auth
  failure. A target mismatch is not an auth failure.
- A project description caps at 255 characters. Put the long text in the
  project spec body.
