---
name: upstream-watch
disable-model-invocation: true
description: Reviews what an upstream project shipped since the last review, ports the changes worth taking into a standalone repository that started from it, and records every decision in that repository's ledger.
---

# Upstream watch

A standalone repository started from another project, the upstream, and shares no Git history with it, so nothing merges on its own. This skill reads what upstream shipped since the last review, decides commit by commit what to take, and records each decision in the repository's ledger: `ledgers/<repository name>.md` in this skill's folder. The ledger is the only memory between reviews, so every decision lands there.

## Steps

1. **Open the ledger** for the repository, named after its GitHub repository (`<repo>.md` for `<owner>/<repo>`). It names the upstream URL and branch, the last reviewed upstream commit, the paths the repository replaced, the rules for taking a change, and the decision log. When no ledger exists, ask Omer for the upstream URL and the upstream commit the repository started from, and create one with the layout of an existing ledger. Done when you hold the upstream URL, the branch and the last reviewed commit.

2. **List what shipped.** In the repository's main checkout:

   ```bash
   git remote get-url upstream || { git remote add upstream <upstream URL>; git remote set-url --push upstream no-push; }
   git fetch upstream
   git log --reverse --format='%H %cs %s' <last reviewed>..upstream/<branch>
   ```

   Add every row of the ledger's "Later" list to the work. When both are empty, set "Last checked" to today, commit the ledger (step 5), and report that upstream shipped nothing. Done when you hold the full list of commits to decide.

3. **Decide each commit.** Read `git show --stat <sha>`, then the diff of each path that matters, then this repository's current version of that file, because the two have diverged. Give each commit one decision with its reason: *take*, *skip*, or *later* (worth taking, but blocked or too large for this round). A change to a replaced path is read by hand and carried over only when our version needs it. Apply the ledger's rules for taking a change. Done when every commit has a decision and a reason.

4. **Port the taken commits** in a worktree on a new branch from the repository's default branch, one commit per upstream commit:

   ```bash
   git show <sha> -- <paths> | git apply --3way
   ```

   Resolve each conflict keeping this repository's side wherever it replaced upstream's code. When the diff no longer applies, port the change by hand from `git show <sha>`. Run the checks the repository's README or `AGENTS.md` names, and land the branch through the repository's normal PR path. Put a schema migration or an auth change in a PR of its own. Done when the PR is merged.

5. **Record the review in the ledger.** Add one row per decided commit to the decision log, oldest first, with the PR URL for a take. Move a *later* commit to the "Later" list and remove it from there once it is decided. Set "Last reviewed" to the newest commit from step 2 and "Last checked" to today. Commit the ledger on the default branch of the repository that holds this skill folder (`git -C <skill folder> rev-parse --show-toplevel`), naming only the ledger path, and push. Done when the pushed ledger's "Last reviewed" equals the newest upstream commit and every commit since the previous review has a row.
