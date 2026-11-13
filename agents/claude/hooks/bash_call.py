"""A Bash tool call as the guard checks read it, built on the tokenizer in bash_segments.

`parse(command, hook_input, deadline)` is the entry. It returns a Call, which reads the command string when a check first
asks for a reading and holds the hook's `cwd`, `agent_id`, and `run_in_background`. A Call's `commands` are every
command the call runs, nested ones included; its `top_level` commands are those the string itself runs, with their
pipes and separators. A Command gives the words bash passes it, its program, its git options and the directory its git
invocation works in, and its ssh parts. A Call also finds the files that a word names, with the variables and `cd`
targets of its commands. `commands_of(text)` reads plain text, such as a here-doc body, as commands.

`deadline` is a time.monotonic() value that every check keeps to, because the hook must answer before Claude Code kills
it at its timeout; a check that cannot finish by then gives up its look, and the dispatcher still prints the reasons it
holds.
"""
import copy
import functools
import glob
import itertools
import math
import os
import re
import time

from bash_segments import (
    BACKGROUND_AFTER,
    CLOSERS,
    SHELLS,
    Operator,
    Position,
    pipe_fed,
    plain_full,
    plain_words,
    program,
    runners,
    segments,
    ssh_parts,
    top_level,
)
from checkouts import git

# Directories tried besides the working directory, words tried as files, and matches taken from one glob. All are
# guesses: past them a command is written to hide a file, and the checks that use these fail open.
MAX_CDS = 8
MAX_WORDS = 4096
MAX_MATCHES = 64
MAX_PATH = 4096
MAX_VALUES = 4
MAX_VARIANTS = 16
LITERAL_ASSIGNMENT = re.compile(r"([A-Za-z_]\w*)=(.*)", re.DOTALL)
VARIABLE = re.compile(r"\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})")
DECLARERS = {"export", "declare", "typeset", "local", "readonly"}
HEREDOC = re.compile(r"(?<!<)<<(-?)[ \t]*(?:\\\n)*(?:'([^'\n]*)'|\"([^\"\n]*)\"|\\?([^\s;&|<>()'\"\\]+))")
MESSAGE_CARRIERS = {"git", "gh", "sandbox-run"}
# `$(cat <<EOF`, with the quote or the name of an assignment that may stand before it.
CAPTURED_CAT = re.compile(r"(\$\(|`)[ \t]*cat[ \t]*$")
ASSIGNED = re.compile(r"(?:^|[\s;&|(])[A-Za-z_]\w*\+?=[\"']?$")
TOPLEVEL = "$(git rev-parse --show-toplevel)"
CREATORS = {"mkdir", "cp", "mv", "rsync", "install", "ln", "tar"}
# Global options that take a value before the git subcommand. `--exec-path` takes its value only as `--exec-path=X`.
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--attr-source"}
AND_GAP = re.compile(r"(?:\s|\\\n)*&&(?:\s|\\\n)*")
PIPE_GAP = re.compile(r"(?:\s|\\\n)*\|(?:\s|\\\n)*")


def _expand(word, env):
    """The variants of word with each `$NAME` and `${NAME}` replaced by a value env gives it. A name with no value
    leaves the word out, because the file it would name is not known."""
    out = [word]
    for _ in range(4):
        nxt = []
        for text in out:
            m = VARIABLE.search(text)
            if not m:
                nxt.append(text)
                continue
            nxt += [text[:m.start()] + value + text[m.end():] for value in env.get(m[1] or m[2], ())]
        out = nxt[:MAX_VARIANTS]
    return [text for text in out if "$" not in text and "`" not in text]


def _existing_files(name, cwd, cds):
    """The regular files that the word name can mean: as given, under cwd, and under each cd target. A glob word
    gives its first MAX_MATCHES matches in each."""
    if not name or "\0" in name or any(c in name for c in "$`"):
        return []
    name = os.path.expanduser(name)
    found = []
    for base in [cwd, *(os.path.join(cwd, d) for d in cds)]:
        pattern = os.path.normpath(os.path.join(base, name))
        if glob.has_magic(pattern):
            paths = itertools.islice(glob.iglob(pattern), MAX_MATCHES)
        else:
            paths = [pattern]
        for path in paths:
            if path not in found and os.path.isfile(path):
                found.append(path)
    return found


def _heredoc_bodies(command):
    """The bodies of the here-docs in the command text, except those that feed a command in MESSAGE_CARRIERS and
    those of a `cat` whose output a bare `$(...)` captures, as in `git commit -m "$(cat <<'EOF'`: that text is an
    argument. A capture assigned to a variable may reach an interpreter later, so it stays."""
    out, cursor, pending_end = [], 0, -1
    for m in HEREDOC.finditer(command):
        if pending_end < m.start() < cursor:
            continue
        newline = command.find("\n", m.end())
        if newline < 0:
            break
        same_line = m.start() <= pending_end
        start = cursor if same_line else newline + 1
        pending_end = pending_end if same_line else newline
        delimiter = next(g for g in m.groups()[1:] if g is not None)
        lines, at = [], start
        while True:
            end = command.find("\n", at)
            line = command[at:] if end < 0 else command[at:end]
            if (line.lstrip("\t") if m[1] else line) == delimiter:
                at = len(command) if end < 0 else end + 1
                break
            lines.append(line)
            if end < 0:
                at = len(command)
                break
            at = end + 1
        cursor = at
        line_start = command.rfind("\n", 0, m.start()) + 1
        before = command[max(line_start, m.start() - 512):m.start()]
        words = re.split(r"[;&|(]", before)[-1].split()
        words = [w for w in words if "=" not in w]
        if words and words[0].rsplit("/", 1)[-1] in MESSAGE_CARRIERS:
            continue
        capture = CAPTURED_CAT.search(before)
        if (capture and not ASSIGNED.search(before[:capture.start()]) and not command[m.end():newline].strip()
                and command[at:].lstrip().startswith(")" if capture[1] == "$(" else "`")):
            continue
        out.append("\n".join(lines))
    return out


def _git_options(args):
    """The global options before a git subcommand as (name, value) pairs, and the index of the subcommand in args. A
    value is the word after an option that takes one, the text after `=`, or None."""
    options, k = [], 0
    while k < len(args) and args[k].startswith("-"):
        if args[k] in GIT_VALUE_OPTIONS:
            options.append((args[k], args[k + 1] if k + 1 < len(args) else None))
            k += 2
        else:
            name, equals, value = args[k].partition("=")
            options.append((name, value if equals else None))
            k += 1
    return options, min(k, len(args))


def _creates(name, args):
    """True when the command can create a directory it names: mkdir and friends, `git worktree add`, `git clone`."""
    if name in CREATORS:
        return True
    words = [a for a in args if not a.startswith("-")]
    return name == "git" and (words[:2] == ["worktree", "add"] or words[:1] == ["clone"])


def _file_words(tokens, words):
    """The words of a command that may name an input file: its arguments and its input redirections' targets, uncut,
    but not what an output redirection writes. A word after `-m` is a Python module, also tried as the file it names."""
    out = []
    for k, (token, word) in enumerate(zip(tokens, words)):
        if word is None or isinstance(token, Operator) or "\0" in word or len(word) > MAX_PATH:
            continue
        if k and isinstance(tokens[k - 1], Operator) and ">" in tokens[k - 1]:
            continue
        out.append(word)
        if k and words[k - 1] == "-m":
            module = word.replace(".", "/")
            out += [module + ".py", module + "/__main__.py"]
    return out


class _Group(list):
    """The commands of one reading of a call, in order, and the directory each git command in them works in. With
    resolve, as for the commands the call itself runs, a `$NAME` in a `cd` or `-C` takes the value of an earlier
    `NAME=value` (also after `export` and its kin), a name the call never assigns comes from the hook's environment,
    and a `cd` to a directory that does not exist, and that no earlier mkdir, cp, mv, `git worktree add`, or `git
    clone` names, fails: the shell skips the commands up to the next separator other than `&&` and runs the ones after
    it in the directory it was in. Without it, as for the commands inside `$(...)`, backticks, and `bash -c`, only
    literal paths resolve and every `cd` is taken to work. An unknown directory is None. Known limit: an assignment or
    `cd` inside `( ... )` counts after the group too."""

    def __init__(self, call, resolve):
        super().__init__()
        self.call, self.resolve, self.tracked, self.connected = call, resolve, False, False

    def connect(self):
        """Give each command that has tokens the connector between it and the next one that has, in one pass."""
        if self.connected:
            return
        self.connected = True
        text = self.call.command
        for command, following in itertools.pairwise(c for c in self if not c.empty):
            gap = text[command._span[1]:following._span[0]]
            command._connector = "&&" if AND_GAP.fullmatch(gap) else "|" if PIPE_GAP.fullmatch(gap) else ""

    def _value(self, word, names, here):
        """The word with each $NAME or ${NAME} replaced, or None when one has no known value or other expansion is
        left. names maps a name the command assigned to its value, None when that value is unknown; names=None leaves
        every name but PWD unknown."""
        if word == TOPLEVEL:
            return None if here is None else git(here, "rev-parse", "--show-toplevel", deadline=self.call.deadline)
        unknown = False

        def value(match):
            nonlocal unknown
            name = match[1] or match[2]
            if name == "PWD":
                found = here
            elif name == "OLDPWD":
                found = None
            else:
                found = None if names is None else names[name] if name in names else os.environ.get(name)
            if found is None:
                unknown = True
                return ""
            return found

        out = VARIABLE.sub(value, word)
        return None if unknown or "$" in out or "`" in out else os.path.expanduser(out)

    def _moved(self, here, word, names):
        target = self._value(word, names, here)
        if target is None or (here is None and not os.path.isabs(target)):
            return None
        return os.path.join(here or "", target)

    def track(self):
        if self.tracked:
            return
        self.tracked = True
        resolve, text = self.resolve, self.call.command
        kept = [c for c in self if c.words] if resolve else list(self)
        chained = [i + 1 < len(kept) and text[kept[i]._span[1]:].lstrip(" \t").startswith("&&")
                   for i in range(len(kept))] if resolve else None
        known = {} if resolve else None
        here, seen, skipping = self.call.cwd, set(), False
        for index, command in enumerate(kept):
            if skipping:
                skipping = bool(chained and chained[index])
                continue
            tokens, at = command.words, command._at
            declaring = at < len(tokens) and tokens[at] in DECLARERS
            if resolve and (at >= len(tokens) or declaring):
                for word in tokens[at + 1:] if declaring else tokens[:at] if at < len(tokens) else tokens:
                    if m := LITERAL_ASSIGNMENT.fullmatch(word):
                        known[m[1]] = self._value(m[2], known, here)
            if at >= len(tokens):
                continue
            name = tokens[at].rsplit("/", 1)[-1]
            if name == "cd":
                targets = [a for a in tokens[at + 1:] if a != "--" and not a.startswith("-")]
                if targets and not command._behind_wrapper:
                    target = self._moved(here, targets[0], known)
                    if chained is not None and target is not None and here is not None \
                            and not os.path.isdir(target) and os.path.normpath(target) not in seen:
                        skipping = bool(chained[index])
                    else:
                        here = target
                continue
            if chained is not None and here is not None and _creates(name, tokens[at + 1:]):
                for word in tokens[at + 1:]:
                    if (target := self._value(word, known, here)) is not None:
                        path = os.path.normpath(os.path.join(here, target))
                        while path not in seen and path != os.path.dirname(path):
                            seen.add(path)
                            path = os.path.dirname(path)
            if name == "git":
                directory = here
                for option, value in command.git.options:
                    if option == "-C" and value is not None:
                        directory = self._moved(directory, value, known)
                command._git_directory = directory


class Git:
    """The global options of a git command as (name, value) pairs, and its words from the subcommand on."""

    def __init__(self, args):
        self.options, at = _git_options(args)
        self.args = args[at:]


class Command:
    """One command a call runs, with the facts the checks ask about it. Words are as bash passes them: quotes
    removed, redirections taken out. `words` keep their first LONG_WORD characters and `full` is uncut; `word` is the
    command word and `program` its name without a directory, for the command that runs after wrappers such as `sudo`
    and `timeout`, and both are "" when there is none. `args` follow the command word, `invocation` is the command word
    and its args, uncut."""

    def __init__(self, call, group, tokens, words, span, piped=False):
        self._call, self._group, self._tokens, self._words = call, group, tokens, words
        self._span, self.piped, self.runner = span, piped, self
        self._git_directory, self._connector = None, None

    @property
    def span(self):
        return self._span

    @functools.cached_property
    def words(self):
        return plain_words(self._tokens)

    @functools.cached_property
    def full(self):
        return plain_full(self._tokens, self._words)

    @functools.cached_property
    def _position(self):
        return Position.of(self.words)

    @property
    def _at(self):
        return self._position.found

    @property
    def _behind_wrapper(self):
        return self._position.wrapper is not None

    @functools.cached_property
    def word(self):
        return self.full[self._at] if self._at < len(self.full) else ""

    @functools.cached_property
    def program(self):
        return program(self.word) if self.word else ""

    @property
    def args(self):
        return self.words[self._at + 1:]

    @property
    def args_full(self):
        return self.full[self._at + 1:]

    @property
    def invocation(self):
        return self.full[self._at:]

    @property
    def shell(self):
        return self.program in SHELLS

    @functools.cached_property
    def git(self):
        return Git(self.args) if self.word.rsplit("/", 1)[-1] == "git" else None

    @property
    def git_directory(self):
        self._group.track()
        return self._git_directory

    @property
    def empty(self):
        return not self._tokens

    @property
    def closes_group(self):
        return not self.words or self.words[0] in CLOSERS

    @property
    def backgrounded(self):
        return BACKGROUND_AFTER.match(self._call.command, self._span[1]) is not None

    @property
    def pipe_fed(self):
        return self._span in self._call._fed

    @property
    def connector_after(self):
        self._group.connect()
        return self._connector

    @functools.cached_property
    def ssh(self):
        return ssh_parts(self._tokens, self._words)

    @functools.cached_property
    def writes_file(self):
        for token, target in itertools.pairwise(self._tokens):
            if isinstance(token, Operator) and not isinstance(target, Operator) and target != "/dev/null":
                op = token.lstrip("0123456789")
                if token[:len(token) - len(op)] in ("", "1") and op in (">", ">>", "&>", "&>>", ">|"):
                    return True
        return False

    @functools.cached_property
    def written(self):
        return [self._words[k + 1] for k, token in enumerate(self._tokens[:-1])
                if self._words[k] is None and isinstance(token, Operator) and ">" in token
                and self._words[k + 1] is not None]

    @functools.cached_property
    def reads(self):
        out = []
        for k, token in enumerate(self._tokens[:-1]):
            op = token.lstrip("0123456789")
            if self._words[k] is None and isinstance(token, Operator) and op in ("<", "<<<") \
                    and self._words[k + 1] is not None:
                out.append((op, self._words[k + 1]))
        return out


class Call:
    """A Bash tool call as the checks read it: the hook's working directory (`cwd`), `agent_id`, and
    `run_in_background`; the `deadline` the checks keep to; every command it runs, those inside `$(...)`, backticks, and
    `bash -c` scripts included (`commands`); and the commands the command string itself runs, with their pipes and
    separators (`top_level`). Each reading happens once, when a check first asks."""

    def __init__(self, command, hook_input, deadline):
        data = hook_input if isinstance(hook_input, dict) else {}
        tool_input, cwd = data.get("tool_input"), data.get("cwd")
        self.command, self.deadline = command, deadline
        self.cwd = cwd if isinstance(cwd, str) and cwd else os.getcwd()
        self.agent_id = data.get("agent_id")
        self.run_in_background = isinstance(tool_input, dict) and tool_input.get("run_in_background") is True
        self._words_left, self._seen_names = MAX_WORDS, set()

    def time_left(self):
        return self.deadline - time.monotonic()

    @functools.cached_property
    def commands(self):
        spans, full = [], []
        found = segments(self.command, spans, full=full)
        group = _Group(self, resolve=False)
        group.extend(Command(self, group, tokens, words, span) for tokens, words, span in zip(found, full, spans))
        for command, k in zip(group, runners(spans)):
            command.runner = group[k]
        return group

    @functools.cached_property
    def top_level(self):
        spans = []
        entries = top_level(self.command, spans)
        group = _Group(self, resolve=True)
        group.extend(Command(self, group, tokens, [None if isinstance(t, Operator) else t for t in tokens], span, piped)
                     for (tokens, piped), span in zip(entries, spans))
        return group

    @property
    def backgrounded(self):
        return any(command.backgrounded for command in self.top_level)

    @functools.cached_property
    def _fed(self):
        return pipe_fed(self.command)

    @functools.cached_property
    def heredoc_bodies(self):
        return _heredoc_bodies(self.command)

    def only(self, commands):
        """A Call that reads variables and `cd` targets from these commands alone, as a check does for the commands
        that run on this host."""
        scoped = copy.copy(self)
        scoped.__dict__.pop("_env", None)
        scoped.__dict__.pop("_cds", None)
        scoped.commands, scoped._words_left, scoped._seen_names = list(commands), MAX_WORDS, set()
        return scoped

    @functools.cached_property
    def _cds(self):
        out = {}
        for command in self.commands:
            tokens, at = command.words, command._at
            if at < len(tokens) and tokens[at] == "cd":
                args = [a for a in tokens[at + 1:] if a != "--" and not (a.startswith("-") and len(a) > 1)]
                if args and "$" not in args[0] and "`" not in args[0]:
                    out[os.path.expanduser(args[0])] = None
                    if len(out) >= MAX_CDS:
                        break
        return list(out)

    @functools.cached_property
    def _env(self):
        """The literal values given to each name by the `NAME=value` words that come before a command or stand alone,
        and by the arguments of `export` and its kin, anywhere in the commands. A value that holds another name is
        read through the values known so far."""
        env = {}
        for command in self.commands:
            plain, at = command.full, command._at
            names = plain[:at] if at < len(plain) else plain
            if at < len(plain) and plain[at] in DECLARERS:
                names = names + plain[at + 1:]
            for word in names:
                if not (m := LITERAL_ASSIGNMENT.fullmatch(word)):
                    continue
                values = env.setdefault(m[1], [])
                for value in _expand(m[2], env):
                    if value not in values and len(values) < MAX_VALUES:
                        values.append(value)
        return env

    def expand(self, word):
        """The variants of word with each variable the commands assign replaced by its values."""
        return _expand(word, self._env)

    def existing_files(self, word):
        """The regular files that word can name, with the variables expanded and relative to the working directory and
        to each `cd` target of the commands."""
        found = []
        for name in self.expand(word):
            found += [path for path in _existing_files(name, self.cwd, self._cds) if path not in found]
        return found

    def named_files(self, command):
        """The regular files that the words of the command name: its arguments and its input redirections' targets.
        Each call spends from one budget of MAX_WORDS distinct names, and a name an earlier command named is skipped."""
        paths = []
        for word in _file_words(command._tokens, command._words):
            for name in self.expand(word):
                if name in self._seen_names:
                    continue
                self._seen_names.add(name)
                if self._words_left <= 0:
                    return paths
                self._words_left -= 1
                paths += [path for path in _existing_files(name, self.cwd, self._cds) if path not in paths]
        return paths

    def read(self, path, cap):
        """The first cap bytes of the regular file at path as text, a relative path taken from the working directory;
        an empty string when it is not a regular file or cannot be read."""
        path = os.path.join(self.cwd, os.path.expanduser(path))
        try:
            if not os.path.isfile(path):
                return ""
            with open(path, "rb") as f:
                return f.read(cap).decode("utf-8", "replace")
        except OSError:
            return ""


def parse(command, hook_input, deadline):
    """The Call for a Bash tool command string and the hook's JSON input, which gives its working directory,
    `agent_id`, and `run_in_background`. deadline is the time.monotonic() value the checks keep to."""
    return Call(command, hook_input, deadline)


def commands_of(text):
    """The commands that plain text, such as a here-doc body, runs."""
    return Call(text, None, math.inf).commands
