# Infisical

Contents: the two projects agents use (below), then the `##` sections Rules, Commands, and Descriptions.

Omer's organization on Infisical EU (`https://eu.infisical.com/api`) holds four projects, and agents use two of them. Their IDs stay out of this public repository: each shell on nixos-desktop, nixos-rog and devbox reads them into `$INFISICAL_PERSONAL_SECRETS_PROJECT` and `$INFISICAL_STATUSLANTERN_PROJECT` from the sops secret `agents-infisical-ids` (nixos-config `nixosModules/agents.nix`).

- `personal-secrets` (id in `$INFISICAL_PERSONAL_SECRETS_PROJECT`, env `secrets`) holds host and
  personal folders; list them with `infisical secrets folders get --env secrets --path /`.
  `/risoluto-fleet` holds the Grok bots' SSH key and Tailscale client, and the URLs and keys of the
  Lead and Builder routine webhooks. The `.infisical.json` in `~/Desktop/workspace` carries this
  workspace id; the recipes below assume that cwd. The EU domain comes from the logged-in user
  config, so no `--domain` flag is needed there. On devbox the CLI has no login: prefix the command
  with `INFISICAL_TOKEN=$(<"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/infisical-agent/token")` and add
  `--projectId "$INFISICAL_PERSONAL_SECRETS_PROJECT" --domain https://eu.infisical.com`,
  because a machine-identity token ignores `.infisical.json` (`reference/devbox.md`, Accounts and logins).
- `statuslantern` (id in `$INFISICAL_STATUSLANTERN_PROJECT`, envs `dev`, `staging`, `prod`) holds only
  `DEVBOX_OMER_SUDO_PASSWORD` under prod `/infra` (`reference/devbox.md`, Sudo). It holds no Status Lantern
  record: Status Lantern keeps every secret in sops in StatusLantern/statuslantern and StatusLantern/inbox
  (statuslantern `docs/secrets.md`), so change a Status Lantern value in sops, never in Infisical. A one-way
  copy of those values sits in a separate Infisical organization, the `infisical@statuslantern.com` login,
  whose projects are also named `statuslantern` and `inbox`; `secrets-mirror` writes it (statuslantern
  `docs/secrets.md`, Mirror), and `$INFISICAL_STATUSLANTERN_PROJECT` is never that copy. Nothing Status
  Lantern-related lives in `personal-secrets`. Address the `statuslantern` project with explicit flags from any cwd:

```bash
infisical secrets --projectId "$INFISICAL_STATUSLANTERN_PROJECT" --domain https://eu.infisical.com \
  --env prod --path /infra -o json --silent | jq -r '.[]?.secretKey'
```

The layout is folders, not a flat root. Root `/` holds nothing that
belongs to a project. Every read, write, delete, and `run` needs an
explicit `--path`, or it silently addresses the root folder and reports
an existing key as absent.

```bash
infisical secrets folders get --env secrets --path /          # list folders
infisical secrets folders get --env secrets --path /harness   # subfolders
```

## Rules

- Never print a secret value. No `cat`, `echo`, `grep`, `head`, `cut`, or
  `sed` on `.env` files. No `infisical secrets` table output; filter to keys
  with the List command below.
- A multi-line secret value's continuation lines have no `=`; splitting a
  dotenv export on `=` (e.g. `cut -d= -f1`) to list key names leaks fragments
  of the value. List key names only with the `-o json --silent | jq` command
  below.
- The agent may write secret values through the CLI when it already has
  the value (another key, a sync, a local file). The constraint is that a
  value never transits chat or stdout: capture to a shell variable, pipe,
  or suppress output. Defer to Omer only when the value is not available
  anywhere.
- Agents create, rotate, or widen a key themselves when a provider API, CLI, or reachable host can do it, and store the value in Infisical without printing it; a Status Lantern value goes into sops instead (statuslantern `docs/secrets.md`). Omer fills a value in the web UI only when the provider needs his own login.

## Commands

Existence check. Report only `missing`, `FILL_ME`, `set`, or the failed read. For a key that
does not exist, `secrets get --plain --silent` prints nothing and exits 0 (observed 24-10-2026
after a delete, and again 04-11-2026), so empty output with exit 0 means missing. A failed read,
such as `secrets get` with `--type`, exits 1 and prints nothing on stdout, so keep its stderr,
where the reason is; `--silent` drops only the CLI's tips. Do not send a secret read's
stderr to `/dev/null`, because an empty value then hides why the read failed, such as a blocked `.envrc`:

```bash
cd ~/Desktop/workspace && \
  if val=$(infisical secrets get KEY --plain --silent --env secrets --path /the-folder); then \
    case "$val" in '') echo missing ;; *FILL_ME*) echo FILL_ME ;; *) echo set ;; esac; \
  else echo "read failed"; fi; unset val
```

A record whose value is empty also reads `missing` here. To prove a record exists or is gone,
use the exit status of `infisical-describe get` (Descriptions, below): 0 when the record
exists, 1 when it does not.

Compare a stored value with a file without printing either. Compare the strings, not
their hashes: `--plain` output and a file often differ only in a trailing newline, and a
hash comparison then reports a false mismatch:

```bash
cd ~/Desktop/workspace && \
  v=$(infisical secrets get KEY --plain --silent --env secrets --path /the-folder) && \
  w=$(cat FILE) && { [ "$v" = "$w" ] && echo match || echo differ; }; unset v w
```

List a folder's keys without values. An empty folder prints `null`, which `.[]?` skips:

```bash
cd ~/Desktop/workspace && \
  infisical secrets --env secrets --path /the-folder -o json --silent | jq -r '.[]?.secretKey'
```

Copy one key to another. The value travels through a 0600 temp file in `.env`
format, never through a command argument, and `secrets set` masks values in its
output by default:

```bash
cd ~/Desktop/workspace && \
  f=$(mktemp) && chmod 600 "$f" && \
  { printf 'DEST_KEY='; infisical secrets get SOURCE_KEY --plain --env secrets --path /the-folder; } > "$f" && \
  infisical secrets set --file "$f" --env secrets --path /the-folder; \
  rm -f "$f"
```

Run an app with secrets injected:

```bash
infisical run --env secrets --path /the-folder -- pnpm dev
```

Delete. Before deleting a record, write a manifest to a 0600 file in the
task's scratch folder: each record's name, the SHA-256 of its value, and its
description, read through stdin or a file so no value is printed. Show it as
the itemized manifest before the delete. A record that only looked unread can
still be a live credential. The manifest holds hashes, not values, so a deleted
value comes back through a revert of the folder's commit history in Infisical.

The default type is `personal`; everything here is `shared`, so
without `--type shared` the CLI returns `404 Secret not found`:

```bash
cd ~/Desktop/workspace && \
  infisical secrets delete KEY --type shared --env secrets --path /the-folder
```

Delete a folder once it is empty:

```bash
infisical secrets folders delete --name the-folder --env secrets --path /parent
```

## Descriptions

Every record carries a description (`secretComment`) so an agent reading the scope knows what
the value is for without opening code. Writing, renaming, moving, or retiring a record includes its
description in the same change. Format, in this order:

1. What the value is, in the code's words, with the property or field it maps to.
2. Who reads it: a file, a script, or a manifest.
3. What it must match, and the procedure pointer for changes (a runbook section, not a copy of it).
4. A record with no reader says so and names the reason: "No reader as of <date>. Candidate for removal."

Bad: "Sudo password for devbox." Good: "Password of the user omer on devbox, which agents pipe
into sudo -S. Must equal omer's password on devbox; reference/devbox.md, Sudo, says how agents
read it."

The CLI has no comment flag; the script below uses the API and compares the description in
the PATCH response with the requested description. It does not perform a separate readback;
complete that check as described below:

```bash
infisical-describe check --projectId <project-id>   # lists env, path, key of records without one; exit 1 if any
printf '%s' 'the description' | infisical-describe set KEY --projectId <project-id> --env <env> --path /the-folder
```

Before reporting an Infisical change as done:

1. Read back metadata for each changed record with `infisical-describe get KEY
   --projectId <id> --env <env> --path /the-folder`, which prints no value. Check its
   project, environment, path, key, and description against the intended change and the
   format above. For a rename or move, also check that `get` exits 1 at the old location.
   For a deletion, check the same; for a retained retired record, check that its
   description states why it has no reader.
2. Run the project-wide `check` above. It detects empty and template descriptions; it
   does not check the full description format. Report failures on unrelated records as
   follow-ups. They do not block completion of the verified change or authorize repairs
   to those records.
3. If an auth, permission, or API error prevents a check, report the missing evidence.
   A failed readback of a changed record blocks completion. An unavailable project audit
   does not block a change whose records were verified independently; report that audit
   as incomplete.

`infisical init` is interactive. For scripted setup pass `--projectId` and
hand-write `.infisical.json`.
