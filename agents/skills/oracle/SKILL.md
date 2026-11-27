---
name: oracle
description: "Asks GPT-6 Pro in ChatGPT for a second opinion on a hard problem through the Oracle CLI. Use only when Omer asks for it: \"ask the oracle\" or /oracle."
---

# Oracle

`oracle` (nixos-config `pkgs/oracle.nix`) pastes a brief and files into ChatGPT in its own Brave Origin window, signed in as Omer, and saves the answer. `~/.oracle/config.json`, which nixos-config `home-manager/profiles/personal.nix` writes, sets browser mode, GPT-6 at Pro effort, the saved login, a background window, and a 60-minute wait for the answer, so a plain `oracle` call needs no model or browser flags. Keep that model: Oracle 0.23.1 has no ChatGPT picker entry for `gpt-6.1-sol`, and `--reasoning-mode` works only in API mode. The model starts with no knowledge of the project and remembers nothing between runs, and each run spends Omer's ChatGPT Pro allowance.

Ask from the command line, not `oracle tui`: in Oracle 0.23.1 the TUI takes its browser settings from this config, but its model list has no `gpt-6-pro` and its prompt starts at `gpt-5.5-pro` (`dist/src/cli/tui/index.js`), so it cannot ask GPT-6 at Pro effort. Run `oracle bridge client` only with `--no-write-config`, because it otherwise replaces `~/.oracle/config.json` with its own copy, and the next Home Manager switch overwrites that copy with no backup.

## Before the run

- `command -v oracle && test -e ~/.oracle/config.json` must pass. It passes on nixos-desktop and nixos-rog; anywhere else, tell Omer the consult needs one of those hosts and stop.
- A run that exits 1 with "manual-login profile is not initialized" needs Omer's one-time sign-in on that host: he runs `oracle --browser-keep-browser -p "HI"`, signs in to ChatGPT in the window it opens within 20 minutes, and closes the window after the answer. Then start the run again. Leave `--browser-cookie-sync` unused, because ChatGPT's token rotation ended a copied session on its second run, and the copy can sign the live browser out.

## Steps

`<dir>` below is `/tmp/agents/<task>-<session8>/oracle/<slug>`, written out in full in every command, because shell variables do not survive between tool calls. `<slug>` is 3 to 5 words of at most 10 letters each, such as `cache-race-root-cause`.

1. Write the brief to `<dir>/brief.md`. A fresh model must be able to answer from the brief and the attached files alone, so it holds, in this order:
   - a briefing of 6 to 30 sentences: the project, its stack, where the relevant code lives, and how to build and test it;
   - the exact question, what was tried, how each attempt failed, and the verbatim errors;
   - the constraints: files that must not change, compatibility, performance budgets;
   - each ChatGPT tool the answer needs: the GitHub plugin with `owner/repo`, the branch, and the paths or the issue and PR numbers, private repositories included; web search or the Exa plugin for facts newer than the model's training. The GitHub plugin reads only pushed code, so attach unpushed changes with `--file`. Ask the model to name the tool behind each answer, or to say the tool was unavailable;
   - the answer shape, such as ranked hypotheses with the evidence that would confirm each, a patch plan, or a decision with its trade-offs.

   Then check the brief for the phrases Oracle reads as a ChatGPT error, such as "sign in", "rate limit", "cloudflare", and "challenge":

   ```sh
   p=$(grep -o 'warningPattern = /[^/]*/' "$(dirname "$(dirname "$(readlink -f "$(command -v oracle)")")")"/lib/node_modules/oracle-cli/node_modules/@steipete/oracle/dist/src/browser/uiWarnings.js | cut -d/ -f2) && tr '_-' '  ' < <dir>/brief.md | grep -inoE "$p"
   ```

   Done when it prints nothing. Oracle 0.23.1 scans the ChatGPT page for these phrases while it waits, the page shows the brief, and `_` and `-` count as spaces, so a brief that holds one exits 1 with "ChatGPT displayed a authentication/challenge warning" although ChatGPT showed none. Reword each line the check prints, such as "log in" for "sign in" and "bot check" for "challenge", and run it again. A clean brief can still exit 1 this way when ChatGPT searches, because Oracle also scans ChatGPT's own status line, such as `Searching developers.cloudflare.com`, while ChatGPT goes on answering (steipete/oracle#634); step 5 recovers the answer once ChatGPT has finished.
2. Pick the smallest file set that still holds the truth. `--file` takes files, directories, and globs, and `!pattern` excludes. Attach no `.env` file, key, token, or other secret. Oracle rejects a file over 1 MB.
3. From the repository root, preview the bundle: `oracle --dry-run summary -s <slug> -p - --file <paths> < <dir>/brief.md`. Its `with ~N tokens` line gives the total, files included, even when the line ends in `prompt only; N attachments excluded`; keep it under about 196k tokens, the limit Oracle's own skill gives. The browser preview prints no per-file sizes, so find the large files with `wc -c` and drop them until the total fits.
4. Write the run to `<dir>/run.sh` and start it detached, because a Pro answer can take minutes (Oracle prints "usually ~10 minutes"), and a detached run survives the tool call's time limit in Claude Code, its subagents, and Codex alike:

   ```sh
   cd <repository root> && oracle -s <slug> -p - --file <paths> --write-output <dir>/answer.md < <dir>/brief.md > <dir>/oracle.log 2>&1; ec=$?; echo "exit $ec" >> <dir>/oracle.log; exit $ec
   ```

   When the brief names a tool, add `--browser-capture-provider-native`, which saves ChatGPT's conversation record for the tool check in step 5, and add `--browser-research search` when it asks for web search. Start it with `setsid bash <dir>/run.sh </dev/null >/dev/null 2>&1 & echo $!`, then wait with `wait-exit --pid <pid> <dir>/oracle.log 540`, and run the wait again after each exit 124. Read the session id from the log's `Reattach via: oracle session <id>` line: Oracle adds `-2`, `-3` to a slug a past run already used, so the id can differ from `<slug>`.
5. Accept the answer only when `<dir>/oracle.log` shows `Model selection evidence: ... resolvedLabel=GPT-6; ... verified=yes` and `Thinking effort evidence: ... resolvedLabel=Pro; verified=yes` and ends with `exit 0`. When the run ended without them, recover it instead of sending the prompt again, because Oracle's duplicate-prompt guard blocks a second send and the first run may still finish: `oracle session <id> --harvest --write-output <dir>/answer.md > <dir>/reattach.log 2>&1`. A harvest writes whatever ChatGPT has shown so far, so accept it only when `<dir>/reattach.log` shows `Capture identity: matched` and `Signals: stop=no`; `stop=yes` means ChatGPT is still answering, so harvest again 2 minutes later. Then look for both evidence lines in `~/.oracle/sessions/<id>/output.log`. When either is still missing, report the consult as unverified, with what is missing.

   When the brief named a tool, list the tools that answered the newest question in the conversation record:

   ```sh
   jq -r '.mapping as $m | [.current_node | recurse($m[.].parent // empty)] | map($m[.].message // empty) | ((map(.author.role=="user") | index(true)) // length) as $i | .[:$i][] | .metadata.invoked_resource.app_name? // empty' ~/.oracle/sessions/<id>/artifacts/*-raw.json | sort | uniq -c
   ```

   `GitHub` is the GitHub plugin, `Exa` the Exa plugin, and `Search Service` web search. A named tool missing from the list did not inform the answer, whatever the answer says; report it so. When the record is missing or `jq` fails, as after a harvest, which saves no record, report the tool use as unverified.
6. Close the Brave window Oracle 0.23.1 can leave running, because its shutdown check reads the first word of the recorded PID's command line (`dist/src/browser/profileState.js`), and on NixOS that PID is Brave's bash wrapper (steipete/oracle#616). Skip this while `oracle status` lists another session as running, because all consults share the window. Otherwise `ps -eo pid,ppid,args | grep "[u]ser-data-dir=$HOME/.oracle/browser-profile"` lists it; stop the `brave` process without a `--type=` flag by its PID. Done when that `ps` prints nothing.
7. Check every claim in the answer against the code, docs, or a run before you act on it, because the answer is advice from a model that saw only the brief. Report to Omer the answer in plain words, which claims you checked and what each check showed, and the session id.

To ask a follow-up in the same ChatGPT conversation, run step 4 with `--followup <id>` in place of `--file <paths>` and the follow-up question as the brief. A follow-up reuses the first run's browser settings and ignores its own flags, so Oracle does not turn web search on; name in its text each tool it needs. It also skips the model picker, so its log has no `verified=yes` model line: accept it when the first run passed step 5 and the follow-up ends with `exit 0`.
