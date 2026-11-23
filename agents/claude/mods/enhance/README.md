# enhance

Turns a rough draft into a clear prompt, and puts it in the prompt box.

- A copy of your session writes the prompt with the `enhance-prompt` skill.
- After the first turn of a session, the copy sees the conversation. In an empty session it starts fresh.
- The copy can read files and run commands to check facts. Its Edit and Write tools are off.
- The prompt is not sent until you send it.

The full description is in [agents/README.md, Mods](../../../README.md#mods). This page is the short version.

## Start a run

| You do | What happens |
| --- | --- |
| Type a draft in the box, press `ctrl+x b` | Runs on the text in the box |
| `/enhance <draft>` | Runs on the text after the command |
| `/enhance-runs` | Opens the list of recent runs |

- `ctrl+x b` is the default chord. A rebind of the keybinding action `app:cycleDiffBase` changes it.
- The chord works only when no run is active and no result is waiting.
- It also needs the `/diff` panel closed and no survey above the box.
- With a result waiting, dismiss it first, or use `/enhance <draft>`. That drops the waiting result.
- An empty box, or `/enhance` alone, starts nothing. A toast says "Type the draft after /enhance".
- One run at a time. A second start shows "An enhancement is already running".

## While it runs

A row appears above the prompt box.

- It shows the seconds so far.
- It shows the tool the copy is calling, and "cold reader" during the last step.
- **Cancel** stops the run.

With no run and no result there is no row. One exception: after a cancel that put the draft back, the row says "Cancelled. The draft is back in the box" until the box changes.

### Questions

- The copy may ask a question in a dialog.
- Answer it, or press Esc.
- After Esc the copy goes on. It writes an `Assuming:` line into the prompt.

### Touching the box

The mod fills the box only when you left it alone during the run.

- Typing counts as touching.
- A slash command counts too, `/enhance-runs` included.
- After a touch, the prompt waits behind **Use prompt**.
- After a touch, a cancelled or failed run does not put the draft back.

## When the prompt is ready

The buttons, in screen order:

| Button | What it does |
| --- | --- |
| Use prompt | Puts the prompt in the box. Shown while the box holds something else |
| Copy prompt | Puts the prompt on the clipboard |
| Restore draft | Puts back what the box held before. Shown while the prompt is in the box |
| Send | Submits the prompt as your next message |
| Revise | Asks what should change. The same copy then rewrites the prompt |
| Notes | Opens the pane with the copy's notes and the prompt |
| Dismiss | Drops the result |

- You can also edit the prompt in the box and press Enter.
- Under the buttons are up to two lines from the notes: `Goal:` and `Effort:`.
- "Draft already clear, nothing changed" means the prompt equals your draft.
- **Cancel** during a Revise brings back the earlier prompt.
- A Revise that fails keeps the earlier prompt. A toast gives the reason.

### The Notes pane

- It opens by itself on a terminal of 144 columns or more.
- On a narrower terminal, press **Notes**.
- It repeats the row's buttons.
- A prompt taller than half the screen hides the row. Use the pane's buttons then.

### Keyboard

- `ctrl+x tab` moves the keyboard to the row or the pane.
- Tab walks the buttons.
- Enter presses one.

## Read the notes before you send

These lines in **Notes** tell you whether to trust the prompt:

- `Understood goal:` is what the copy thinks you want.
- `Cold reader:` is a second run of the writer model, with no tools. It says what it would do with the prompt. The line is missing when that run fails or takes more than 120 s.
- `Not in the prompt:` names a path, URL or code span from your draft that the prompt lacks.
- `Cost: $0.12, time: 34 s` is the last line. It says `Cost: not reported` when Claude Code gave no cost.

In the prompt itself, each `Assuming:` line is a guess the copy made for you.

## When a run fails

The row starts with "✗ Enhance failed:" and has **Retry**, **Details** and **Dismiss**.

| The row says | Do this |
| --- | --- |
| the writer model … does not exist, or this account cannot use it | Set Writer model in `/config` |
| the account's … limit is reached | Wait for the reset, or set another Writer model |
| the model refused; retrying will not help | Change the draft, or run it from a new session |
| the copy's turn did not end in … s | Retry, or raise Turn time limit in `/config` |
| this session's folder … was deleted | Restart Claude Code in an existing folder |
| anything else | Press Details for the full text and the copy's reply, then Retry |

- The draft goes back into the box when the box is empty and untouched.
- A run that ends ready or failed sends a notification: "Enhanced prompt is ready" or "Enhance failed". A cancelled run sends none.

## Get a draft or a prompt back

`/enhance-runs` opens the runs pane.

- The card on top is this session's last draft, with **Put draft in box**. It appears after you start a run in this session.
- Below it are the 10 newest runs, newest first.
- Each run has two lines. The first has the outcome (✓ enhanced, ✗ failed, ○ for the rest), how long ago it started, its seconds and its cost. The second is the first line of the draft.
- A fact the record lacks, and a cost of 0, are left out. A cost under half a cent shows as `<$0.01`.
- **Copy prompt** is on each run that has a prompt.

## Settings

Three rows in `/config`:

| Setting | Default | What it sets |
| --- | --- | --- |
| Writer model | `claude-sonnet-5-5` | The model the copy runs on |
| Writer effort | `high` | The copy's effort: `low`, `medium`, `high`, `xhigh` or `max` |
| Turn time limit (seconds) | 570 | How long one turn of the copy may take |

Changing a setting reloads the mod. A result that is ready is lost then.

## Run records

Each run that ends writes one JSON file:

```
${XDG_STATE_HOME:-~/.local/state}/enhance/runs/<start time>-<run id>.json
```

- It holds the draft, the prompt, the notes, the model, the cost and the turns.
- Records older than 30 days are deleted when a session starts.
- The files hold your drafts and prompts as plain text.

`sent` says what you did with a prompt:

| Value | Meaning |
| --- | --- |
| `as-is` | You sent the prompt unchanged |
| `edited` | You sent it after changing it |
| `own-draft` | You sent your own draft instead |
| `dropped` | You dismissed it, or a new run or the session's end replaced it |
| `null` | The run failed or was cancelled, or the result is still waiting |

List the runs:

```sh
jq -r '[.startedAt, .seconds, .outcome.kind, .sent] | @tsv' "${XDG_STATE_HOME:-$HOME/.local/state}"/enhance/runs/*.json
```

## More

- How the copy runs, its permissions and every record field: [agents/README.md, Mods](../../../README.md#mods).
- Install on another machine: [Install enhance on another machine](../../../README.md#install-enhance-on-another-machine).
- The rules the copy follows: [`agents/skills/enhance-prompt/SKILL.md`](../../../skills/enhance-prompt/SKILL.md).
