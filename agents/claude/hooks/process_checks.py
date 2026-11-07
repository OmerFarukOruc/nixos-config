"""Checks on calls that start, stop, or hide processes: `pkill -f` and `pgrep -f`, a run of a script or corpus that
holds a kill command and executes commands, a subagent's call or an `&` inside a run_in_background call, and a build
whose exit status a pipe drops.

A full-command-line pattern also matches the shell that runs it, because the pattern is part of that shell's own
command line. A here-doc body counts when the same call runs a shell, `source`, or a command named by a path on this
host, because the body may be the script that runs, and the Bash tool's shell holds the whole call, body included, in
its command line.

A subagent that ends its turn while its own background call runs sits idle, and the completion notice goes to the
parent session. Claude Code sets `agent_id` in the hook input only when the hook fires inside a subagent, and it runs a
run_in_background call in the background itself, so an `&` inside it lets the call end while the work still runs.

`nix build ... 2>&1 | tail -2` exits with tail's status, so a failed build looks like a success, and Nix 2.34 ends a
failed build with "Output paths:" and the path it would have made. Only commands the call itself runs are read for the
pipe check, so a build inside `$(...)` or a `bash -c` script passes.

The script run check reads what the call names. When the call runs an interpreter, a runner such as `uv run`, or
`source`, the evidence is
- the words of each interpreter command, wrappers such as `xargs` included, so `-c` text counts,
- every here-doc body, except one that feeds git or gh, or that a bare `$(cat <<EOF ...)` captures as an argument,
  such as a commit message,
- the text of a here-string that an interpreter reads, or that a piped command carries,
- every file that a word of the call names, and every `<` target of an interpreter, from commands other than git, gh,
  wc, and the like; formatters and linters such as prettier, ruff, and shellcheck, and grep, rg, and ls, count only
  when their output may reach another command (a pipe that does not end in head, tail, tr, wc, sort, uniq, or cut
  printing to the terminal, a file other than /dev/null, a `$(...)`), a `sed -i` whose script is only substitutions and
  a `sed -n` whose script only prints lines by number never count unless their output flows on, and cp and mv always
  count; so a corpus that `cat` or a loop's `< file` passes on counts too; a word may hold a variable that a
  `NAME=value` in the call sets, or a glob; a compiled program (an ELF file) never counts, because a shell binary such
  as /bin/sh holds its own kill and eval builtins, so the kill text inside a compiled helper goes unseen too,
- the text of an `echo` or `printf` that writes a file an interpreter command names, that an interpreter reads from
  stdin, that a pipe or a `<(...)` hands on, or that the call has an interpreter with a `<` or `<<<` redirect for.
Text that other commands carry, such as a commit message, is not evidence. The call is denied when the evidence holds
a construct that executes commands and holds `pkill`, `killall`, or a `kill` followed by an option other than `-0`,
`-l`, or `-L`, a `%` job, or a PID, variable, quote, or substitution.
A `kill` of the script's own background job does not count, so a script that stops its own helper, such as nixpkgs'
Gradle `fetch-deps.sh` with its mitm-cache proxy, runs. Such a `kill` has at most one signal option (`-SIG`, `-s SIG`,
`-n NUM`) and `--`, then only operands that are `"$!"`, `"$NAME"`, or `"${NAME}"`, or one `'$NAME'` that closes a
double-quoted trap string, as in `trap "kill '$PID'" EXIT`; after them come only `/dev/null` redirects and the end of
the command. Every NAME is one the shell never sets itself (not `_`, RANDOM, PPID, REPLY, BASH*, and the like), and
appears in the text only as `$NAME` or `${NAME}` reads and in exactly one earlier line that starts at the first column
and is `NAME=$!` or `NAME="$!"`, alone or after a ` & ` that ends the job's command. The check reads text: it does not
see a column-one assignment inside an unindented function, `if`, or subshell. A Claude Code transcript (a .jsonl
file under the projects folder of a `~/.claude*` folder or of CLAUDE_CONFIG_DIR) records a session's commands, kill
commands and execution words alike, so its text counts toward the kill evidence only, and so does a file whose text is
one JSON document or JSON Lines, such as an agent's report, because no interpreter runs JSON: a script that reads one
passes, and a script, xargs, or eval that runs what it holds still brings its own execution construct. `sandbox-run`
runs a command with no host processes, so a command that starts with it adds no evidence and is not an interpreter
run, and neither is a command named without a `/` that only parses: a shell with `-n`, such as `bash -n script.sh`,
`node --check file`, or `python3 -I -m py_compile file`, nor a formatter or linter that a runner starts, such as
`uv run ruff check file` or `npx prettier --check file`. A command that `ssh` or `tailscale ssh` runs on another host
is left out too: a file of this host does not show what it runs there, and `sandbox-run` cannot fence it. ssh to this
host's name or a loopback address still counts.

The check is static. It does not follow imports, a corpus name that a script holds inside itself, a directory argument,
a file larger than FILE_CAP past its first FILE_CAP bytes, ruby, php, lua, or R (not interpreters here), or the first
MAX_MATCHES matches of a glob in a directory of more files. A here-doc is exempt by its first word, so
`git -c alias.x='!sh' x <<EOF` is too. An `echo` inside `$(...)` counts as evidence, and a file read after the
TOTAL_CAP budget is spent counts as clean. No deny does not show a run is safe. A run of the hook's own source is
denied by itself: it holds both kinds of text.

Every check fails open: a command that does not parse, or a file that cannot be read, lets the call through.
"""
import itertools
import json
import os
import re
import socket
import subprocess

from bash_call import commands_of

# Bytes read from each file (guess; the incident corpora were up to 7.5 MB) and from all files of one call.
FILE_CAP = 20 << 20
TOTAL_CAP = 32 << 20
# Seconds before the call's deadline when the scan for execution constructs stops and denies, because the evidence holds
# a kill command and the scan cannot show the rest is harmless. A pattern takes up to 1 s per 20 MB (measured with
# text built to make it slow), and the hook timeout lets the call through.
SCAN_RESERVE = 2.0
INTERPRETER = re.compile(r"python(?:\d+(?:\.\d+)*)?|pypy\d*|node|perl|bash|sh|zsh|dash|ksh|fish")
# Commands that run a script or a text that a word names.
RUNNERS = {"source", ".", "eval", "uv", "poetry", "pipx", "npx", "pnpm", "bun", "deno", "tsx"}
SHEBANG = re.compile(r"#![ \t]*(?:\S*/)?(?:env[ \t]+(?:-\S+[ \t]+)*)?(?:" + INTERPRETER.pattern + r")(?![\w.-])")
# Tools that read the files they get as text and never run them, although their shebang names node or python; by
# basename.
CHECKERS = {"prettier", "oxfmt", "oxlint", "biome", "tsc", "eslint", "knip", "shellcheck", "shfmt", "ruff", "black",
            "isort", "pyright"}
# The words after each runner that start the command following them, and the runner options that take no value.
RUN_PREFIXES = {"uv": [("run",), ("tool", "run")], "poetry": [("run",)], "pipx": [("run",)], "pnpm": [("exec",)],
                "bun": [("x",)], "npx": [()]}
FLAG_ONLY = {"--frozen", "--locked", "--offline", "--no-sync", "--no-project", "--isolated", "-q", "--quiet", "-y",
             "--yes"}
# Shells whose `-n` option parses a script without running a command of it.
NOEXEC_SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
ISOLATED_PY_COMPILE_OPTIONS = {"-I", "-B", "-E", "-s", "-q"}
# The name that stands for a command that only parses its files, such as a shell run with `-n`, in the rows of a call.
PARSER = "<parse only>"
# Commands whose file arguments are never read as input to an interpreter; grep, rg, and ls pass their files on only
# when their output may reach one.
NEVER_FEEDS = {"git", "gh", "wc", "stat", "rm", "chmod", "sandbox-run", PARSER}
FILTERS = {"grep", "egrep", "fgrep", "rg", "ls"}
# Commands that pass text on without running it; a filter whose output ends in them and then in the terminal hands
# nothing to another command. `sort -o` and the output operand of `uniq` write a file, so they are left out.
TEXT_FILTERS = {"head", "tail", "tr", "wc", "sort", "uniq", "cut"}
SORT_OUTPUT = re.compile(r"-[A-Za-z]*o|--output")
EXECUTION = [re.compile(p) for p in (
    (r"\b(?:subprocess\.|Popen\(|os\.(?:system\(|popen\(|exec|spawn)|pty\.spawn|child_process"  # Python, Node
     r"|(?:system|exec)\s*\(|eval\b|xargs\b)"),  # Perl, shells
    r"`[^`\n]*\$[^`\n]*`",
    r"sh[ \t]+(?:-[\w-]+[ \t]+)*[\"']?\$",  # a shell run on a variable's value
    r"(?<![^\s;&|(])(?:source|\.)[ \t]+[\"']?\$",  # a variable's value read as a script
)]
# `kill -0` sends no signal; it only checks that a process exists. `kill -l` and `kill -L` list signal names. A word
# after `kill` that cannot be a target, as in "kill commands", is prose.
KILL = re.compile(r"""pkill|killall|\bkill\s+(?:%|-(?!0\b|[lL]\b)|[0-9$"'`(])""")
CHILD_KILL_HEAD = re.compile(r"""kill(?:[ \t]+(?:-[sn][ \t]+(?:\w+|"\$\w+"|"\$\{\w+\}")|-\w+))?(?:[ \t]+--)?""")
CHILD_OPERAND = re.compile(r"""[ \t]+(?:"\$!"|"\$([A-Za-z_]\w*)"|"\$\{([A-Za-z_]\w*)\}"|"""
                           r"""'\$\{?([A-Za-z_]\w*)\}?'"(?=[ \t]|$))""", re.MULTILINE)
CHILD_KILL_END = re.compile(r"(?:[ \t]+[12]?>[ \t]*/dev/null|[ \t]+2>&1)*[ \t]*(?:[;&|)]|$)", re.MULTILINE)
CHILD_PID_LINE = re.compile(r"""(?=[^\s#])(?:(?:[^\n(){}#;'"`&|]|>&)*[ \t]&[ \t]+)?"""
                            r"""([A-Za-z_]\w*)=(?:\$!|"\$!")[ \t]*""")
# Variables that bash or zsh set themselves, so an earlier `NAME=$!` does not decide what they hold at the kill.
SHELL_SET = re.compile(r"_|RANDOM|SRANDOM|SECONDS|EPOCH\w*|LINENO|PPID|BASHPID|UID|EUID|GROUPS|HISTCMD|OPTARG|OPTIND"
                       r"|REPLY|MAPFILE|PIPESTATUS|FUNCNAME|PWD|OLDPWD|SHLVL|COLUMNS|LINES|DIRSTACK|HOSTNAME|HOSTTYPE"
                       r"|MACHTYPE|OSTYPE|(?:BASH|COMP_|READLINE_)\w*")
PROBE_REASON = (
    "This runs commands from a script or corpus that holds pkill/killall/kill, and a PATH stub does not stop the real "
    "binary (`env -i`, absolute paths). Run it as `sandbox-run [--rw DIR] [--ro PATH] -- <command>`, with --ro PATH "
    "for each input outside the working folder, which the sandbox does not show. When a command only reads or edits a "
    "file this message names, run it in a separate Bash call with no interpreter in it, or edit the file with the Edit "
    "tool. A script may stop its own background job without the sandbox: save the PID once on an unindented line, "
    "`cmd &` then `pid=$!` (or `cmd & pid=$!`), and stop it with `kill \"$pid\"` or `kill -s TERM \"$pid\"`.")
# One sed substitution whose flags write or execute nothing, such as `s/a/b/g`, and the separator after it.
PLAIN_SUBSTITUTION = re.compile(r"\s*s([^\s\\])(?:\\.|(?!\1).)*\1(?:\\.|(?!\1).)*\1[gIip0-9]*\s*(?:;|$)", re.DOTALL)
LINE_PRINT = r"(?:\d+|\$)(?:\s*,\s*(?:\d+|\$))?\s*p"
LINE_PRINTS = re.compile(rf"{LINE_PRINT}(?:\s*;\s*{LINE_PRINT})*(?:\s*;)?")

# A bundle of short flags that has an f, as in `-af`, whatever follows it: a value attached to a later option, as in
# `-fd,`, or a character the tool refuses. `pkill -9f x` is not matched: pkill reads a leading number as the signal
# only when the whole word is one (procps 4.0.4, `strtol` must reach the end of `9f`), and getopt then refuses the `9`.
SHORT_FULL = re.compile(r"-[a-zA-Z]*f")
SCRIPT_RUNNERS = {"source", "."}
PROCESS_MATCH_REASON = (
    "A `-f` pattern matches whole command lines, so it can match this shell's own command line and processes of "
    "other sessions, such as an MCP proxy; `pgrep -f` can list them and `pkill -f` can kill them. Every `-f` call "
    "is refused. Find the PID with `ps -eo pid,args | grep ...`, check it with `ps -p <pid>`, then act on that PID.")
PROCESS_MATCH_SCRIPT_REASON = (
    "A here-doc in this call holds `pgrep -f` or `pkill -f`, and the call runs a shell, `source`, or a "
    "script by its path. The Bash tool's shell holds the whole call, here-doc included, in its command "
    "line, so the pattern matches that shell too. Take the PID from `$!` where the script starts the "
    "process, or write the script in one Bash call and run it in another.")
SUBAGENT_REASON = (
    "A subagent runs every command in the foreground: when it ends its turn while its own background call runs, it "
    "sits idle and the completion notice goes to the parent session. Run this call again without run_in_background; "
    "split a command longer than the Bash tool's 600000 ms limit into slices that each fit.")
AMP_REASON = (
    "This call already runs in the background, and its `&` makes the call end at once, so the completion notice "
    "would arrive before the work ends. Drop the `&` and let the command run in the foreground of this background "
    "call.")
BUILD_SCRIPTS = {"build.sh", "check.sh", "checks.sh", "unit-cycles.sh"}
BUILD_PROBE = re.compile(r"nix|devenv|build\.sh|checks?\.sh|unit-cycles\.sh")
EXIT_KEPT = re.compile(r"pipefail|pipestatus", re.IGNORECASE)
NIX_OPTION_VALUES = {"--option": 2, "--arg": 2, "--argstr": 2, "--override-input": 2,
                     "--extra-experimental-features": 1, "--experimental-features": 1, "--log-format": 1, "-I": 1,
                     "--include": 1, "--store": 1, "--eval-store": 1, "--builders": 1, "--max-jobs": 1, "-j": 1,
                     "--cores": 1}
BUILD_PIPE_REASON = (
    "This build or check pipes its output into another command, so the pipe's exit status is the last command's and "
    "a failed build reads as a success; Nix 2.34 even ends a failure with \"Output paths:\". Send the output to a log "
    "and print the exit status, then read the end of the log: `cmd > LOG 2>&1; echo \"exit $?\" >> LOG; tail -n 20 "
    "LOG`. A command that needs the pipe can start with `set -o pipefail;`.")
THIS_HOST = {"localhost", socket.gethostname().split(".")[0].lower()}
# A name whose first label starts with a letter, so no IPv4 form such as `127.1` or `0x7f000001` is a name.
DNS_NAME = re.compile(r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*")
# ssh options that send the connection somewhere other than the destination word, or run a local command.
REROUTES = re.compile(r"hostname|proxycommand|localcommand|permitlocalcommand", re.IGNORECASE)
# Seconds `ssh -G` may take; it read the config in 0.01 s on devbox on 2026-10-21, and the hook timeout is 10 s.
SSH_G_TIMEOUT = 2
HOSTNAMES = {}


def _plain_substitutions(script):
    """Whether a sed script is only substitutions that write or execute nothing."""
    at = 0
    while at < len(script):
        m = PLAIN_SUBSTITUTION.match(script, at)
        if not m or m.end() == at:
            return False
        at = m.end()
    return at > 0


def _sed_parts(words):
    """The options and the scripts of a sed call. GNU sed also reads the options that follow its files, so every word
    up to `--` counts; without `-e`, the first word that is not an option is the script."""
    options, scripts, operands, rest = [], [], [], iter(words[1:])
    for w in rest:
        if w == "--":
            operands += rest
        elif w in ("-e", "--expression"):
            scripts.append(next(rest, ""))
        elif w.startswith("--expression="):
            scripts.append(w.split("=", 1)[1])
        elif w.startswith("-") and w != "-":
            options.append(w)
        else:
            operands.append(w)
    return options, scripts or operands[:1]


def _edits_in_place(words):
    """Whether a sed call only substitutes text in its files in place, so their text reaches no other command and its
    script writes or runs no other file."""
    options, scripts = _sed_parts(words)
    in_place = any(re.fullmatch(r"-[A-Za-z]*i\S*|--in-place(?:=\S*)?", w) for w in options)
    reads_script = any(re.fullmatch(r"-[A-Za-z]*f\S*|--file(?:=\S*)?", w) for w in options)
    return (in_place and not reads_script and bool(scripts)
            and all(_plain_substitutions(s) for s in scripts))


def _prints_lines(words):
    """Whether a sed call only prints lines of its files by number, as `sed -n 1,5p FILE` does, so it reads them
    the way grep does."""
    options, scripts = _sed_parts(words)
    quiet = any(re.fullmatch(r"-[Ersn]*n[Ersn]*|--quiet|--silent", w) for w in options)
    return (quiet and bool(scripts) and all(re.fullmatch(r"-[Ersn]+|--quiet|--silent", w) for w in options)
            and all(LINE_PRINTS.fullmatch(s.strip()) for s in scripts))


def _reads_only(words):
    """Whether a sed call only substitutes in place or only prints lines by number, so it runs nothing it reads."""
    return _edits_in_place(words) or _prints_lines(words)


def _is_transcript(path):
    """Whether the real path, so not a link to a corpus elsewhere, is a .jsonl file in a Claude Code transcript
    store."""
    real = os.path.realpath(path)
    home = os.path.realpath(os.path.expanduser("~"))
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    stores = re.match(re.escape(home) + r"/\.claude[^/]*/projects/", real) or (
        config and real.startswith(os.path.join(os.path.realpath(config), "projects", "")))
    return real.endswith(".jsonl") and bool(stores)


def _is_json_data(text):
    """Whether the text is one JSON document or JSON Lines, such as an agent's report, which no interpreter runs."""
    try:
        json.loads(text)
        return True
    except ValueError:
        pass
    lines = [line for line in text.splitlines() if line.strip()]
    try:
        return bool(lines) and all(isinstance(json.loads(line), (dict, list)) for line in lines)
    except ValueError:
        return False


def _parses_only(target, args, command):
    """Whether the command only parses its files: a shell that `-n` (or fish's `--no-execute`) keeps from running
    anything, `node --check` or `-c` with files and no other option and no NODE_OPTIONS in the call, which preloads
    code, or python with `-I` before `-m py_compile`, without which a `py_compile.py` in the current directory runs.
    A target written with a `/` may be a binary of the corpus, so it never counts."""
    if "/" in target:
        return False
    if target == "node":
        return ("NODE_OPTIONS" not in command and args[:1] in (["--check"], ["-c"])
                and not any(word.startswith("-") for word in args[1:]))
    if target.startswith("python") and INTERPRETER.fullmatch(target):
        k = next((i for i, word in enumerate(args) if word not in ISOLATED_PY_COMPILE_OPTIONS), len(args))
        return "-I" in args[:k] and args[k:k + 2] == ["-m", "py_compile"]
    if target not in NOEXEC_SHELLS:
        return False
    for word in args:
        if not word.startswith("-") or word in ("-", "--"):
            return False
        if re.fullmatch(r"-[A-Za-z]*n[A-Za-z]*", word) or word == "--no-execute":
            return True
    return False


def _runs_checker(name, args):
    """The checker a runner starts, as in `uv run --frozen ruff check FILE`, or None; an option that may take a value
    makes the word after it unknown, so such a call stays a runner."""
    for prefix in RUN_PREFIXES.get(name, ()):
        if tuple(args[:len(prefix)]) == prefix:
            rest = list(itertools.dropwhile(lambda w: w in FLAG_ONLY, args[len(prefix):]))
            rest = rest[1:] if rest[:1] == ["--"] else rest
            return rest[0] if rest and rest[0] in CHECKERS else None
    return None


def _reads_stdin(args):
    """Whether the interpreter command with these arguments reads its script from stdin: only options and `-`."""
    return all(w.startswith("-") for w in args)


def _child_kill_names(text, at):
    head = CHILD_KILL_HEAD.match(text, at)
    if not head:
        return None
    names, end = [], head.end()
    while operand := CHILD_OPERAND.match(text, end):
        names.append(operand.group(operand.lastindex) if operand.lastindex else None)
        end = operand.end()
        if operand.group(3):
            return names
    return names if names and CHILD_KILL_END.match(text, end) else None


def _bang_save_offset(text, name):
    if SHELL_SET.fullmatch(name) or re.search(rf"(?<!\S)-[A-Za-z]+{name}(?!\w)", text):
        return None
    saves = []
    for m in re.finditer(rf"(?<!\w){name}(?!\w)", text):
        start, end = m.start(), m.end()
        if text[start - 1:start] == "$" or text[start - 2:start] == "${" and text[end:end + 1] == "}":
            continue
        line_start = text.rfind("\n", 0, start) + 1
        line_end = text.find("\n", start)
        line = CHILD_PID_LINE.fullmatch(text, line_start, len(text) if line_end < 0 else line_end)
        if not (line and line.start(1) == start):
            return None
        saves.append(start)
    return saves[0] if len(saves) == 1 else None


def _holds_kill(texts, call):
    for text in texts:
        if "kill" not in text:
            continue
        saves = {}
        for m in KILL.finditer(text):
            if m.group(0) in ("pkill", "killall"):
                return True
            names = _child_kill_names(text, m.start())
            if names is None:
                return True
            for name in filter(None, names):
                if call.time_left() < SCAN_RESERVE:
                    return True
                if name not in saves:
                    saves[name] = _bang_save_offset(text, name)
                if saves[name] is None or saves[name] > m.start():
                    return True
            if call.time_left() < SCAN_RESERVE:
                return True
    return False


def _holds_execution(texts, call):
    for text in texts:
        for pattern in EXECUTION:
            if call.time_left() < SCAN_RESERVE or pattern.search(text):
                return True
    return False


def _is_full_match(command):
    if command.program not in ("pkill", "pgrep"):
        return False
    for arg in command.args:
        if arg == "--":
            break
        # GNU getopt takes an unambiguous prefix of a long option, so `--f` is `--full`.
        if SHORT_FULL.match(arg) or (len(arg) > 2 and arg.startswith("--") and "--full".startswith(arg)):
            return True
    return False


def _runs_script(command):
    return command.shell or command.program in SCRIPT_RUNNERS or "/" in command.word


def _process_match_reason(call):
    if any(_is_full_match(command) for command in call.commands):
        return PROCESS_MATCH_REASON
    if not any(_is_full_match(command) for body in call.heredoc_bodies for command in commands_of(body)):
        return None
    if any(_runs_script(command) and not _runs_elsewhere(command.runner, call) for command in call.commands):
        return PROCESS_MATCH_SCRIPT_REASON
    return None


def _background_reason(call):
    if not call.run_in_background:
        return None
    if call.agent_id:
        return SUBAGENT_REASON
    return AMP_REASON if call.backgrounded else None


def _nix_subcommands(args):
    """The first two words of a nix command line that are neither options nor option values."""
    found, k = [], 0
    while k < len(args) and len(found) < 2:
        arg = args[k]
        if arg.startswith("-"):
            k += 1 + (0 if "=" in arg else NIX_OPTION_VALUES.get(arg, 0))
        else:
            found.append(arg)
            k += 1
    return found


def _builds(command):
    """Whether the command runs a build or a check whose failure a pipe would hide."""
    name, args = command.program, command.args
    if command.shell:
        script = next((a for a in args if not a.startswith("-")), None)
        runs_string = any(a.startswith("-") and not a.startswith("--") and "c" in a for a in args)
        return script is not None and not runs_string and script.rsplit("/", 1)[-1] in BUILD_SCRIPTS
    if name == "nix":
        subcommands = _nix_subcommands(args)
        return subcommands[:1] == ["build"] or subcommands == ["flake", "check"]
    if name == "nix-store":
        return any(a == "--realise" or re.fullmatch(r"-[a-zA-Z]*r[a-zA-Z]*", a) for a in args)
    if name == "devenv":
        return [a for a in args if not a.startswith("-")][:1] == ["test"]
    return name == "nix-build" or name in BUILD_SCRIPTS


def _build_pipe_reason(call):
    if not BUILD_PROBE.search(call.command) or EXIT_KEPT.search(call.command):
        return None
    return BUILD_PIPE_REASON if any(c.pipe_fed and _builds(c) for c in call.top_level) else None


def _runs_elsewhere(command, call):
    """Whether the command is `ssh` or `tailscale ssh` to another host. Only a literal DNS name counts, one whose first
    label is not this host's short name or a `localhost` form; for `ssh`, the HostName that `ssh -G` gives the name
    must pass the same test, so a config alias that points back here counts as here. An IP address, a variable, or a
    glob may be this host as far as the hook knows, and so may a call that sets HostName, ProxyCommand, or a config
    file."""
    parts = command.ssh
    if not parts or not parts[1]:
        return False
    options, destination, _ = parts
    if any(REROUTES.search(w) or re.fullmatch(r"-[A-Za-z]*F\S*", w) for w in options):
        return False
    url = destination.startswith("ssh://")  # ssh://[user@]host[:port]
    host = destination.removeprefix("ssh://").rsplit("@", 1)[-1]
    if url:
        host = host.rsplit(":", 1)[0]
    if not _names_another_host(host):
        return False
    if command.program == "tailscale":
        return True
    return _names_another_host(_ssh_hostname(destination, tuple(_config_options(options)), call))


def _names_another_host(host):
    first = host.split(".")[0].lower()
    return bool(DNS_NAME.fullmatch(host)) and first not in THIS_HOST and not first.startswith(("localhost", "ip6-"))


def _config_options(options):
    """The `-o`, `-l`, and `-p` options among an ssh call's option words, which change what `ssh -G` reports; other
    options, such as `-E FILE`, could write files."""
    out = []
    for k, word in enumerate(options):
        if word in ("-o", "-l", "-p") and k + 1 < len(options):
            out += [word, options[k + 1]]
        elif re.fullmatch(r"-[olp]\S+", word):
            out.append(word)
    return out


def _ssh_hostname(destination, options, call):
    """The HostName that OpenSSH gives destination with these options, from `ssh -G`, which reads the config, runs its
    `Match exec` lines, and connects to nothing; "" when ssh fails or the call's time is spent, so the run counts as
    here. Every command that one ssh call runs asks the same question, so the answer is kept."""
    key = (destination, options)
    if key not in HOSTNAMES:
        out = ""
        if call.time_left() > 0:
            try:
                out = subprocess.run(["ssh", "-G", *options, "--", destination], stdin=subprocess.DEVNULL,
                                     capture_output=True, text=True, timeout=min(SSH_G_TIMEOUT, call.time_left()),
                                     check=False).stdout
            except (OSError, subprocess.SubprocessError, ValueError):
                out = ""
        HOSTNAMES[key] = next((line.split(None, 1)[1].strip() for line in out.splitlines()
                               if line.startswith("hostname ")), "")
    return HOSTNAMES[key]


def _command_target(word, call):
    """The command word with its variables expanded to the first value each has, or "" when one has none."""
    names = call.expand(word) if "$" in word else [word]
    return names[0] if names else ""


def _runs_interpreter(name, call):
    """Whether the command word name is an interpreter or a runner, or a path to a file whose shebang names one."""
    base = name.rsplit("/", 1)[-1]
    if base in CHECKERS:
        return False
    if INTERPRETER.fullmatch(base) or base in RUNNERS:
        return True
    return "/" in name and any(SHEBANG.match(call.read(path, 256)) for path in call.existing_files(name))


def _is_text_filter(command):
    """Whether the command only passes its standard input on as text: a TEXT_FILTERS command that writes no file."""
    if command.program not in TEXT_FILTERS:
        return False
    if command.program == "sort":
        return not any(SORT_OUTPUT.match(w) for w in command.args)
    if command.program == "uniq":
        return sum(w == "-" or not w.startswith("-") for w in command.args) < 2
    return True


def _output_flows(call, to_files):
    """The plain words of each command the call itself runs, mapped to whether its output may reach another command:
    it goes into a pipe that does not end in text filters and the terminal, or with to_files into a file, or a later
    `done`, `fi`, `}`, or `)` that goes into one may close its group."""
    entries = call.top_level
    onward, closed = [], False
    for command in reversed(entries):
        flowing = command.piped or to_files and command.writes_file
        closed = closed or flowing and command.closes_group
        onward.append(flowing or closed)
    onward.reverse()

    def reaches_a_command(k):
        """Whether the pipe after entry k leads past the text filters that follow it."""
        for j in range(k + 1, len(entries)):
            if not _is_text_filter(entries[j]):
                return True
            if not onward[j]:
                return False
        return True

    flows = {}
    for k, command in enumerate(entries):
        words = tuple(command.words)
        flows[words] = flows.get(words, False) or onward[k] and (not command.piped or reaches_a_command(k))
    return flows


def _kill_sources(call):
    """The files, or the call's own text, that hold a kill command next to a construct that runs commands, among the
    commands of the call; an empty list when there are none."""
    rows, interpreters = [], []
    for command in call.commands:
        if not command.word:
            rows.append((command, ""))
            continue
        target = _command_target(command.word, call)
        name = target.rsplit("/", 1)[-1]
        checker = _runs_checker(name, command.args)
        if _parses_only(target, command.args, call.command):
            name = PARSER  # reads its files as text, like a checker
        elif checker:
            name = checker
        rows.append((command, name))
        if name in ("sandbox-run", PARSER) or checker:
            continue
        if target and _runs_interpreter(target, call):
            interpreters.append(command)
    if not interpreters:
        return []
    flows = {False: _output_flows(call, False), True: _output_flows(call, True)}

    def flows_on(command, to_files=False):
        """Whether the output of the command may reach another command; a command inside `$(...)` or a script may.
        to_files also counts a redirect into a file, as grep, rg, and ls stage a filtered copy; the file an echo
        writes is matched by name instead."""
        return flows[to_files].get(tuple(command.full), True)

    redirects = [r for command in interpreters for r in command.reads]
    named = {w for command in interpreters for w in command.invocation} | {t for op, t in redirects if op == "<"}
    stdin = any(_reads_stdin(command.args) for command in interpreters)
    texts = [" ".join(command.full) for command in interpreters] + call.heredoc_bodies
    texts += [t for op, t in redirects if op == "<<<"]
    for command, name in rows:
        if name in ("echo", "printf"):
            written = {os.path.normpath(t) for w in command.written for t in call.expand(w)}
            if (stdin or redirects or flows_on(command)
                    or written & {os.path.normpath(t) for w in named for t in call.expand(w)}):
                texts.append(" ".join(command.invocation))
        elif name not in NEVER_FEEDS and flows_on(command):
            texts += [t for op, t in command.reads if op == "<<<"]
    kill_files = ["the command's own text"] if _holds_kill(texts, call) else []
    budget, files, transcripts = TOTAL_CAP, [], []
    feeders = [command for command, name in rows
               if name not in NEVER_FEEDS and (name not in FILTERS | CHECKERS or flows_on(command, True))
               and not (name == "sed" and _reads_only(command.full) and not flows_on(command, True))]
    paths = []
    for command in feeders:
        paths += [path for path in call.named_files(command) if path not in paths]
    for path in paths:
        if call.read(path, 4) == "\x7fELF":
            continue
        text = call.read(path, min(FILE_CAP, budget))
        budget -= len(text)
        (transcripts if _is_transcript(path) or _is_json_data(text) else files).append(text)
        if _holds_kill([text], call):
            kill_files.append(path)
    texts += files
    # Kill text is the rarer of the two, so most files need no pass for the execution patterns.
    if kill_files and _holds_execution(texts, call):
        return kill_files
    return []


def _probe_run_reason(call):
    local = call.only(c for c in call.commands if c.runner is c or not _runs_elsewhere(c.runner, call))
    sources = _kill_sources(local)
    if not sources:
        return None
    return (f"{PROBE_REASON} Kill text found in: {', '.join(sources[:5])}"
            + (f" and {len(sources) - 5} more." if len(sources) > 5 else "."))


CHECKS = (_process_match_reason, _background_reason, _probe_run_reason, _build_pipe_reason)
