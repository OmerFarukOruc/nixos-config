---
name: agent-browser
description: Drives a real browser with the agent-browser CLI on Omer's machines, including his signed-in sessions. Use for a page that needs clicking, typing, a login, JavaScript rendering, or a dashboard (Cloudflare, Tailscale, Linear, ChatGPT, GitHub settings), and for screenshots. Not for a public page a plain fetch can read.
allowed-tools: Bash(agent-browser:*), Bash(box-browser:*), Bash(login-code:*), Bash(scp devbox:*)
---

# agent-browser

agent-browser is a browser CLI: `open <url>`, `snapshot -i` (the page's controls as `@e1`, `@e2` refs), `click @e2`, `fill @e3 "text"`, `get text`, `eval <js>`, `screenshot`. Learn the commands from the installed version first:

```bash
agent-browser skills get core          # workflows, patterns, troubleshooting
agent-browser skills get core --full   # every command and template
```

`agent-browser skills list` names the specialised guides, such as `electron` and `slack`.

## Pick the browser

Each session drives its own **session**, pinned to its own tab, so sessions never move each other's page. `box-browser` takes the session name from `--session`, else `AGENT_BROWSER_SESSION`, else `CLAUDE_CODE_SESSION_ID`, else `CODEX_THREAD_ID`. A subagent uses a browser only when its prompt names its session, `<parent session>-<agent name>`, which it passes with `--session`.

| Need | Browser | Command prefix |
|---|---|---|
| any signed-in page, from any host | devbox's box browser: Chromium on a hidden display, running at all times | `box-browser` (over SSH from a PC) |
| a passkey-only site's cookies, or a login the box lacks with Omer at his PC | Omer's Brave Origin on the PC you run on | `box-browser --brave` |
| the same, from devbox | Omer's Brave on nixos-desktop or nixos-rog, after he runs `browser-lend on` there | `box-browser --brave --on <machine>` |
| a public page only | a throwaway headless browser | `agent-browser --session <name>` |

The throwaway browser stops at Cloudflare's `Just a moment...` check, which store.kde.org shows. Open such a page with the box browser, or use the site's API.

The box browser comes first because it never waits for Omer, while each new Brave session waits for his Allow click (below), so a Brave call while he is away fails. Chromium offers only the on-or-off policy `RemoteDebuggingAllowed` (chromeenterprise.google/policies/remote-debugging-allowed), and the request to remember an approval, ChromeDevTools/chrome-devtools-mcp#825, was open with no fix on 2026-11-04 (`gh issue view 825 -R ChromeDevTools/chrome-devtools-mcp`).

From a PC, `box-browser` sends the command to devbox over SSH with each argument quoted, so a URL with `?` or spaces needs only the local shell's quotes, and stdin reaches the remote command. A file the box browser writes, such as a screenshot, stays on devbox; copy it back with `scp devbox:<path> <local scratch path>`.

Omer's Brave asks him to click Allow once for each new session. The first `box-browser --brave` call of a session waits up to 10 minutes for it. In a Claude Code main session, run that call with `run_in_background` and end the turn with a line that names the machine where Omer must click Allow. A subagent or another CLI runs it in the foreground with its longest tool timeout. When a call is cut short, the next call waits again. Pass `--brave` on every command of the session, because it passes `--cdp` each time: a session that never attached then fails instead of opening a local browser. Keep `AGENT_BROWSER_DEFAULT_TIMEOUT` and the other daemon settings the same for the whole session, because a changed setting restarts the session's daemon, and Brave asks again.

## Signed-in work

- Use the box browser freely, within the task's normal authorization: ask before a destructive or irreversible action the request does not name, and before any of these unless the request names it: a payment, a password, 2FA or recovery change, a mail forwarding rule, an OAuth app or API token grant, and an account or data deletion. In Omer's local or lent Brave, a click, a read, or a write the task already authorizes needs no request; a login is his to type, and other automation there needs his request or his yes to an offer.
- The box browser lacks a login when its page lands on a sign-in form. When the account's password, and its TOTP seed if it has one, sit in a secret store this session reads, sign the box browser in yourself: pipe the value into `box-browser eval --stdin` as a script that sets the field through the input's value setter and returns only a boolean, so the value never reaches a command line or the output, and compute the TOTP code from the seed in the same pipe. On 2026-11-05 this signed the box browser in to GitHub and then to Tailscale through "Sign in with GitHub". When the site sends a code by email, take the time, request the code, then run `login-code --after <time>` (nixos-config `docs/box-browser.md`, Login codes) to write it to a 0600 file, and enter it the same way, so the code never reaches a command line or the output; when the sender has no forwarding filter yet, the command finds no mail, and adding the filter is Omer's step. Leave mailboxes closed in the box browser: it holds no mail account. When neither works, and only then, ask Omer to run `box-view` and sign in to the page and account you name, quoting the step that failed, because a login made there stays for every later agent; with Omer at a PC, the step may instead move to his local Brave. A site that accepts only a passkey gets its cookies copied once from his Brave, local or lent to devbox: `cookies get --url <site>` on the Brave session, `cookies set` on the box session; print cookie names and counts, never values.
- Print no cookie, token, secret, or signed URL. Mask a URL's query and fragment when you report it.
- Cloudflare API calls, reads and writes, use an API token from the caller's secret store, the way the caller's docs name it, instead of a dashboard form or the dashboard's cookies, because a token works headless and its rights are written down.
- On a page that shows a secret, read no page text (`get text`, `snapshot`, an `eval` that returns text), even with the value replaced, because the page can repeat part of it elsewhere. Cloudflare's new-token dialog repeats the token's first characters in its example `curl`, and `snapshot -i` prints the value of every input. Find elements with an `eval` that returns only a count or a boolean, or mark one with a `data-` attribute as below. Compare the value across reads by hash (`eval` that returns the first 8 hex digits of its SHA-256), save it with `download <sel> <path>` into a 0700 directory, or, when the page has no download control, run `(umask 077; <browser command> eval '<expression that returns only the value>' | jq -j . > "$d/token")`, with the session's command from the table, and print only `wc -c < "$d/token"`. Store the file in its target, such as Infisical through a file or stdin, then delete it.

## When an action does nothing

- When `fill` or `click` reports success and the page stays the same, count the matches and act on the visible one, because a page can render a hidden copy of a dialog per table row. Mark it with `eval` that sets a `data-` attribute on the element with a non-zero `getBoundingClientRect()`, then target that attribute.
- On the box browser, a page that a click changed can stay undrawn until a screenshot is taken: after clicking Linear's "Enter code manually", `eval` found 0 inputs until `box-browser screenshot <file>` ran, then found 1 (agent-browser box browser on nixos-desktop, 2026-11-09). Take a screenshot to a scratch file and delete it before you look for the new element.
- Clear a field with `press Control+a` and `press Backspace`, then enter text with `fill` or `keyboard type`; `type` garbled the text in Tailscale's fields.
- Screenshot the element you need, `screenshot <selector> <path>`, because a full page on a HiDPI Brave is 3841x1840 and costs far more to read.
- Tailscale trust-credential descriptions allow 50 characters; above that, Continue stays disabled with no message.
- "Sign in with GitHub" on Tailscale, in a Brave signed in to two GitHub accounts, went through GitHub's account picker and landed on `https://tailscale.com/a/oauth_response`, a 404, with no login (2026-11-05). The same sign-in in the box browser, signed in to one GitHub account, reached the console.
- When a button's `click` does nothing on a sign-in or OAuth page (Tailscale's provider buttons, GitHub's account picker), submit its form with `eval` and `button.form.requestSubmit(button)`. A button with no form, such as Save in Tailscale's JSON policy editor, ignored `click @ref` and `find role button click` on 2026-11-08 and sent no request; `eval` that calls the visible button's `.click()` saved it. Confirm a save by reloading the page and comparing what it shows.

## Mail links

Check a `mailto:` link by reading its target, `get attr <selector> href`, and leave it unclicked. In Omer's Brave a click opens Thunderbird on his screen. A throwaway browser on his workstations lands on "This page is blocked" instead, because nixos-config `nixosModules/chromium.nix` blocks `mailto:` in Chromium; that page is the machine's policy, not a fault of the site.

## When done

Run `agent-browser --session <name> close` for a throwaway browser. On a shared browser (box, lent, local Brave), `close` detaches your session and leaves the browser running; close only tabs your session opened. On Omer's Brave, run `box-browser --brave close` with `close` as the first word of the command, because the wrapper skips the wait for Allow only then.
