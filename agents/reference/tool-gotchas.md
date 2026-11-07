# Tool gotchas

Facts the tools do not print. Confirm a flag with `--help` before relying on it.

## gh

- To check how GitHub renders a Markdown file, run `gh api markdown -F text=@<file> -f mode=gfm -f context=<owner>/<repo>` and count the tags you expect, such as `<table`. It needs no browser. A headless Chrome screenshot of the blob page loaded without styles and cut off before the table. The output carries no heading ids, so check anchors with a link checker.
- To read an issue as a spec or campaign, run `gh-issue-tree <owner/repo> <n> <dir>`. It saves the body, every comment, and every sub-issue from the sub_issues API, and owners record scope decisions in comments. `gh issue view` leaves comments out unless `--json` names `comments` or the plain view gets `--comments`.
- `gh search issues` does not search GitHub Discussions. Search them with `gh api graphql -f q='repo:<owner>/<repo> <words>' -f query='query($q:String!){search(query:$q,type:DISCUSSION,first:10){nodes{... on Discussion{number title url closed}}}}' --jq '.data.search.nodes[]'`.
- `gh issue view --json` needs an explicit comma-separated field list; a bare `--json` fails.
- `gh issue list --author app/<name>` misses a GitHub App's issues, though the same filter works on `gh pr list`. Use `--author '<name>[bot]'`.
- `gh issue create --parent N` creates a sub-issue. `gh issue edit N --add-sub-issue M` links an existing issue.
- Run `gh secret set` in an interactive terminal, or pipe the value from a 0600 file. Through the `!` prefix it stores what stdin holds and never prompts, so the secret can be empty.
- `gh api` prints the error body on stdout when the request fails, with or without `--jq`. A missing ref prints `{"message":"Not Found",...,"status":"404"}` and exits 1. Use the output only when the exit code is 0, so a check that tests for non-empty output does not read a missing tag as present.
- `gh ... --jq -c` reads `-c` as another flag. For compact output end the filter with `| tostring`.
- To find a run you just dispatched, filter `gh run list` on `createdAt` with a time read from `date -u` in the same command, before the dispatch. A typed time can lie after the run and the wait never ends.
- `gh pr checks <n>` prints each check's link, and a Cloudflare Workers Builds check links to the dashboard with the account id in its path. Read checks with `gh pr checks <n> --json name,state,bucket`, which leaves the link out, instead of redacting the output with a hex pattern that also cuts commit SHAs. `--watch` refuses `--json` (``cannot use `--watch` with `--json` flag``), so run `gh pr checks <n> --watch > /dev/null`, then read the result with `--json name,state,bucket`.
- Right after `gh pr create`, `gh pr checks <n>` prints `no checks reported` and `--watch` has nothing to wait on. Poll `gh api "repos/<owner>/<repo>/actions/runs?head_sha=<sha>" --jq .total_count` until it is above 0, then run `gh pr checks <n> --watch`.
- To wait for a PR's required checks and then merge, run `pr-land <n>` in the background from the main checkout. It waits for the base branch's required checks, or the PR's own checks when none are readable, in any repository (`PR_LAND_WAIT`; default 1800 seconds for the checks wait, 13200 seconds where the merge controller merges the PR), so it needs no separate waiter.
- To wait for the checks on a commit that is no PR's head, such as the default branch after a merge, run `gh-wait-checks <owner/repo> <sha> <seconds> [name-regex ...]` in the background; it reads check runs, not commit statuses, and `--help` lists its exit codes. `gh run watch` sees only Actions runs, and a GitHub App's check, such as Cloudflare Workers Builds, can appear after the Actions run starts, so name each such check as a regex and the wait does not end before it appears.
- `gh api .../actions/jobs/<id>/logs` exits 1 with only a stderr notice when the log holds terminal escape codes, which most CI logs do. Pass `--allow-escape-sequences`, and keep stderr apart from the saved log so the notice cannot pass for an empty log.

## GitHub Actions

- A run queued into a `concurrency` group cancels the group's pending run, even with `cancel-in-progress: false`. Rerunning or dispatching an older run in a deploy group can cancel the head's pending build.
- The repository setting `sha_pinning_required` also applies to the actions that a composite action uses. Before turning it on, read each pinned action's `action.yml` at its SHA and check every `uses:` in it. It once failed every kernel-cache job at "Set up job", because `wimpysworld/nothing-but-nix` uses `srz-zumix/post-run-action@v3`.
- A `run:` step without `shell:` runs as `bash -e {0}`, without pipefail, so `script | tee` passes when the script fails. Set `shell: bash`, which adds `-o pipefail`.

## Git

- A shallow clone (`.git/shallow` present) hides real parents, so `git rev-list` and graph views report false divergence. Run `git fetch --unshallow` or use the GitHub compare API before trusting the local graph.
- A git hook runs with `GIT_INDEX_FILE`, `GIT_DIR`, and similar variables set for its own repo, and every git command it starts inherits them, even with `-C` on another repo. A script that a hook runs and that uses git elsewhere first unsets the names `git rev-parse --local-env-vars` prints.
- `git log --since=2026-09-05` starts at the current time of day on that date and drops the earlier commits. For a whole-day window write `--since="2026-09-05 00:00"`.
- A dependency-bump PR can change a version string but keep the old checksum, or skip a second file its manager does not match. Before merging, check every place the old version or its hash appears.
- A major SDK bump can change the provider API version the SDK speaks; stripe-java pins one Stripe API version per major, and it reads a webhook event only when the event's version matches. Before merging, compare the SDK's pinned version with the provider-side setting, such as the webhook endpoint's API version. Green CI cannot show the mismatch, because tests build their own events.

## Codex app threads

- `codex_app__list_threads` rejects `limit` above 50.
- Before archiving a session, check its status and the linked tracker issue's state, never the title alone. Keep active, deferred, pinned, and unrelated work.
- A remote task inventory shows title, status, cwd, task id, and host, filtered to the requested host: active work first, then loaded idle work, then historical entries.
- A result left only in a delegated thread may not reach the parent. When the parent asks, send it a direct message with the pointer.

## AWS CLI

- Run a write over many items (a backfill, a stamp, a row copy) in one process: boto3, or `aws dynamodb batch-execute-statement` with up to 25 conditional PartiQL statements per call. One `aws` process per item stamped 1,600 DynamoDB rows in over 10 minutes in one run (unsupported beyond that run), long enough to overrun a foreground tool call.
- `--cli-input-json file://...` cannot read a pipe. On aws-cli 2.38.1, `file:///dev/stdin`, `file:///dev/fd/0`, `file:///proc/self/fd/0`, and a `<(...)` process substitution each failed with `Invalid JSON received` (exit 252), and the same JSON from a regular file worked; 2.37.13 failed the same way on `file:///dev/stdin`. To keep a secret out of argv, write the JSON to a 0600 file and pass `file://<path>`.

## Bash tool shell

- To pause inside a loop, run `sleep 0.5`.
- Claude Code can hold a Bash call whose `bash -c` or `sh -c` script it cannot read for removals, such as a command whose text holds `docker run --rm`, behind a prompt that an unattended session never answers. The rule is under "Claude Code" in nixos-config `agents/claude/CLAUDE.md`. Write the script to a file and run `bash <file>` instead.

## Shell of Codex and SSH commands

Claude Code's Bash tool runs bash. Codex runs `zsh -lc`, and a remote login shell is zsh on the hosts that set it, so these hold there.

- `g` is an alias for `git` and `gd` for `git diff`, so a shell function named `g` or `gd` fails to define. Pick another name.
- zsh does not split an unquoted expansion into words, so `${x:+--flag "$x"}` passes one argument, `--flag value`, and the command rejects it as an unknown flag. Build optional flags as an array: `opt=(); [[ -n $x ]] && opt=(--flag "$x"); cmd "${opt[@]}"`.
- zsh's `read -t` does not wait for its timeout, so `read -rt 0.5 <> <(:)` returns in about 1 ms (measured on zsh 5.9.2), while bash waits 0.5 s. To pause inside a loop, run `zmodload zsh/zselect; zselect -t 50`, which counts in hundredths of a second.

## Terminal apps

- To read the exact colors a terminal app draws, run it outside tmux under `script` with stdin held open, then count the truecolor sequences: `sleep 14 | env -u TMUX COLORTERM=truecolor timeout 15 script -q -O <file> -c '<app>' >/dev/null; grep -a -o -E '[34]8;2;[0-9]+;[0-9]+;[0-9]+' <file> | sort | uniq -c`. `tmux capture-pane -e` returns 256-color approximations, and stdin from `/dev/zero` fills the file with NUL bytes.
- To drive Claude Code's TUI through tmux, such as to see how it draws a reply, start it as `tmux new-session -d -s <s> -x <cols> -y <rows> 'claude --add-dir <dir>'`, with `--add-dir` for each folder outside the working directory that it must read, because each such read otherwise stops at a permission question. Send the prompt as `tmux send-keys -t <s> -l '<text>'`, then `tmux send-keys -t <s> C-m` as its own call, because a long prompt sent with its key in the same call stayed in the input box. Count lines with `tmux capture-pane -p -S -500 -t <s> | grep -c '<pattern>'`, where `-S -500` adds scrollback because a long reply pushes earlier lines off the screen. Before the prompt, count the lines that start with `● ` and the turn-end lines that contain `· done`, such as `✻ Crunched for 1s · done 16:09Z`. Send `C-m` again, a few seconds apart, until the `● ` count grows, then wait under `timeout` until the `· done` count grows by one. Counting works where a wait on reply text fails, because a table can split that text across cells and an earlier turn's output stays on screen.

## Waiting on a process

- `until ! pgrep -f '<pattern>'` never ends: the pattern also matches the shell's own command line (`bash -c` in Claude Code, `zsh -c` in Codex) that runs the loop. Wait on the PID with `while kill -0 <pid>`, and find the PID with `ps -eo pid,args | grep '[c]dp_drive.py'`; the `bash-guard.py` hook denies every `-f` pattern.

## SSH

- The login shell of `oruc` on nixos-rog and nixos-latitude, and of `omer` on devbox, is zsh, so `ssh <host> '...'` runs its command in zsh, and an unquoted `?` or `*`, such as in `echo status=$?`, aborts it with "no matches found". Send a multi-line or glob-bearing command as `ssh <host> 'bash -s' <<'EOF'`. Put values into the script, not after `--`, because ssh joins its arguments into one string that the remote zsh splits again, so `ssh <host> bash -s -- "$value"` breaks a value with a space and runs one with a `;`.
- For a remote command longer than a line or with quotes inside quotes, write the script to a file and run it with stdin closed: `scp -q file <host>:/tmp/<name>.sh && ssh <host> 'bash /tmp/<name>.sh </dev/null; rc=$?; rm -f /tmp/<name>.sh; exit $rc'`. Write values into the file's first lines with `printf 'value=%q\n' "$value"`. The file has one quoting layer. `bash -n file` and `shellcheck file` check it before it runs, and a fix reruns the same file.
- `ssh <host> bash -s < file` and `ssh <host> 'bash -s' <<'EOF'` feed the script on stdin, so a command in it that reads stdin, such as `ssh`, `cat`, `read`, or another `bash -s`, reads the rest of the script and the run ends there with exit 0, so a proof script can run only its first step and still report success. In a here-doc, give each such command `</dev/null`; for a script file, use the `scp` form above.
- `data | ssh <host> bash -s <<'EOF'` runs the data as code: zsh joins a pipe and a heredoc into one stdin, pipe first, so the remote bash reads the data as script lines; a `git archive` stream, for example, runs line by line until a line in it calls `exit`. Send the data and the script in separate `ssh` calls.
- `timeout N ssh <host> '<cmd>'` stops only the local `ssh`; the remote command keeps running. Put the timeout on the remote side: `ssh <host> 'timeout -k 5 N <cmd>'`.
- `timeout N nix fmt` can leave treefmt running past the SIGTERM (over 50 s in one run). `timeout -k 5 N` adds a SIGKILL and stopped it at N + 5 s.

## wl-copy

- `cmd | wl-copy` copies the newline that ends `cmd`'s output, and `infisical secrets get --plain` ends with one, so a password pasted from the clipboard carries it and the login fails. Copy with `wl-copy -n` (`--trim-newline`).
- `ssh <host> '... | wl-copy'` never returns: `wl-copy` forks a process that serves the clipboard and keeps the SSH channel's stdout and stderr open. Redirect them, `wl-copy >/dev/null 2>&1`, and stop that process by its PID when the test ends.

## Headless browsers

- For a headless page check, such as whether an API exists or what a permission's state is, run `cdp-eval EXPRESSION URL...`. Brave Origin opens `chrome://brave-origin-startup/` first, so `--dump-dom` never returns, and the nixpkgs wrapper keeps Brave running after `timeout` kills the wrapper; `cdp-eval` reads the page over the DevTools port and stops the browser's whole process group. On a host without agent-tools, run `ssh <host> "python3 - ${(q)expression} URL..." < "$(command -v cdp-eval)"`.

## Searching and reading

- Read large files, or several files, in bounded sections. One combined read truncates silently.

## Claude Code settings

- To learn whether Claude Code has a `settings.json` key or an environment variable for something, run `cc-setting KEY` (nixos-config `pkgs/agent-tools`), with the exact name or a word in it, such as `cc-setting concurrent`. For a variable the code reads outside its environment schema, such as `BASH_DEFAULT_TIMEOUT_MS`, it prints the code around the read, which often shows the default. It reads the installed binary and takes 0.06 s for a settings key, up to 1.5 s for another exact name, and about 4 s for a word as broad as `_` (measured on nixos-desktop). `grep` prints only "Binary file matches" for the 280 MiB binary, so read it through `cc-setting`.
