---
name: disk-cleanup
description: "Propose what to delete, what to look at, and what to leave on this host, each with a measured size."
disable-model-invocation: true
---

# Disk cleanup

Build a disk-reclaim **proposal** for this host: three lists (delete, look, and leave), then one question. Deleting waits for a later message that names what to delete.

`scripts/survey.py` is the command; it runs the modules beside it: `config.py` holds the floor, the windows, and the class tables, `measure.py` the walks and size estimates, `classify.py` the rules that sort paths into rows (`own_class`), `activity.py` the check for work that running agents hold, `docker.py` and `host_rows.py` the rows for other tools, and `report.py` the printed text. `scripts/tables.json`, merged with this host's overlay `${XDG_STATE_HOME:-~/.local/state}/disk-cleanup/tables.<hostname>.json`, and `own_class` are the class list, so a class change is an edit there. A person edits `tables.json`, which every host shares; only learn.py writes the overlay, and the overlay stays on its host. [references/choices.md](references/choices.md) holds the measurements and choices behind each window and path set. `scripts/remove.py` owns the delete checks, in the order its docstring lists. `scripts/holders.py` owns the process check both scripts use. `scripts/learn.py` owns the run records and the rules that update this host's overlay.

## 1. Survey

Run the survey in one Bash call with a 600000 ms timeout:

```
python3 ~/.claude/skills/disk-cleanup/scripts/survey.py
```

A traceback is the survey failing; quote its last line and stop.

The survey removes nothing. On 31-10-2026 it took 4 min 44 s to 6 min on nixos-desktop, where it proposed 22 delete rows, and 42 to 84 s on nixos-rog. It takes longer when the delete rows hold many GiB, since the estimate reads every compressed byte once, and when agent folders in `/tmp/claude-<uid>` grow (they held 25 GiB on 06-10-2026). It prints the proposal draft in Markdown and writes the uncapped list, with every group's paths, to the path on its last line.

Done when the survey printed its three lists.

## 2. Reply with the proposal

The survey's text, tables, order, sizes, and reasons are the proposal. Reply with that draft as printed, and end with one question as numbered options:

1. Delete all delete rows (recommended, because each delete row's Comes back cell says what returns and what does not)
2. Delete only the rows you name
3. Stop

When the delete list is empty, ask whether to look into the largest look row instead.

The reply is the last message of the turn. Omer reads in focus mode, where only the final message shows, so the lists and the question travel in that one message.

Done when the reply holds the three lists and ends on the question.

## 3. Delete

Run this step only after a later message says to delete all delete rows or names some. Run one of these in one Bash call, a background one in Claude Code (see below):

```
python3 ~/.claude/skills/disk-cleanup/scripts/remove.py --all
python3 ~/.claude/skills/disk-cleanup/scripts/remove.py PATH...
```

A PATH is a row's path, a group such as `group:stale-cache`, or one entry from a group's full list, such as a path, a Docker image reference, a volume name, or a container name. A Docker look row, such as a local build, an untagged image a live session named, or a young volume, goes only by hand after Omer checks its evidence. A look row whose reason includes "Trash when named" goes to the Trash, and a later survey's `~/.local/share/Trash` row frees its space. A stale `/tmp` folder goes to the Trash too, and a survey 7 days later offers it as `group:tmp-trash`.

The script takes its rows from the latest survey, so when this session has not run the survey, run step 1 first. `--dry-run` runs the checks and removes nothing. Exit 1 means a check or the removal kept a path; the table names the cause, and the path stays.

`remove.py --all` took 17 min 36 s on nixos-desktop on 06-11-2026 (the Bash call's start to its completion notice), longer than the 600000 ms Bash timeout, because the 19 delete rows included 12.5 GiB of Trash and 4280 stale `/tmp` folders. In Claude Code, start it with `run_in_background`, log its output to a file that ends with an exit line, and end the turn with one line that says it is running; the completion notice starts the turn that reads the table and runs step 4. In another harness, run it in the foreground with a timeout above that time, or poll the log with `wait-exit`.

A `ghcr.io` image that remove.py keeps with `check 6` and `403` in its Result cell may need a registry login; a 403 also comes from a deleted or unreadable package, which a login does not fix. The table shows only a group's first kept entry, so for each `ghcr.io` entry of `group:docker-untagged` and `group:docker-images` that Omer approved, run `remove.py --dry-run REF` and read its Result cell. When `gh auth status` shows the `read:packages` scope and `~/.docker/config.json` has no `ghcr.io` key under `auths` or `credHelpers`, log in yourself with `gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin`. Then run the survey again, because the entries' references come from the latest survey, run `remove.py REF...` on only the approved entries that check 6 kept, and run `docker logout ghcr.io` even when a step failed, because without a credential helper the token stays in `~/.docker/config.json`. An entry that stays kept after the login is reported as kept, and an entry the new survey adds to the group goes to Omer as a new proposal. When the scope is missing or a `ghcr.io` key already exists, the login needs Omer.

Done when remove.py printed its table.

## 4. Update the skill and reply

Run this step in the turn that answers the proposal's question, after step 3 when it runs; when step 3 ran in the background, run it in the turn that the completion notice starts, after remove.py's table is read. When the survey printed a Skill updates section:

1. Run every edit marked "applies now" in one Bash call, each as `python3 ~/.claude/skills/disk-cleanup/scripts/learn.py ARGS`. Each prints the diff of this host's overlay, which learn.py creates on the first edit. Commit and push nothing: the overlay lives outside the repository.
2. An edit marked "asks" allows more deletion, so it waits for Omer. For an `unlisted` rule, replace REASON with how the path's bytes come back.

The edits change this host's overlay only; the checks in holders.py and remove.py, and this step list, stay as they are.

Reply with remove.py's table as printed, then each applied edit's diff, then, when an edit asks, one question as numbered options: 1. apply it, 2. decline it. On a yes, apply it as in item 1. On a no, run `learn.py decline` followed by the edit's arguments.

Done when the reply holds each result this step produced.
