"""Split a Bash tool command into the commands it runs, for the PreToolUse guard hooks.

bash_call.py builds the Call that the guards read on top of segments, top_level, pipe_fed, and the word helpers here;
no guard imports this module.

Each shell line and each `&&`, `||`, `;`, `|`, `&`, `(`, or `)` segment is one command. Quoted text stays
inside its word across newlines, so a commit message that names a command is not read as that
command; here-doc bodies and `#` comments are dropped for the same reason. Commands that bash runs from
inside another one count too: backticks, `$(...)`, `<(...)`, and `>(...)` outside single quotes, the
script of `bash -c` and similar shells, `$SHELL -c` and `$BASH -c` included, a here-doc or here-string that a shell reads as its script, the
text of `echo`, `printf`, or a here-doc or here-string fed to `cat` that a pipe hands to such a shell, also from a
`( ... )` or `{ ...; }` group, a compound command such as `for` or `if`, or a function's call, through `cat` or
`tee`, and to any shell in a group that the pipe feeds unless its input comes from a file, the remote command
of `ssh` and `tailscale ssh`, the command of `find -exec`, the command line of `env -S` and `flock FILE -c`,
and the words after `eval`, down to MAX_DEPTH
levels and within the NESTED_SHARE budget.

`env -S` also reads `${NAME}` as env does, from the names assigned before it, among the arguments of an env before it,
or exported earlier in the command.

The scan is linear in the command's length: a guard that Claude Code kills at its hook timeout lets the
call through. Words keep their first LONG_WORD characters; a cut bundle of short flags such as
`-uuu...f` keeps each of its letters, because the guards look for one letter anywhere in it.
"""
import bisect
import functools
import re
import shlex

# The word after `<<`: quoted parts, escaped characters, and plain characters up to a blank or an operator. A word
# with `$'`, `$"`, or `$(` does not match, because bash expands the first two and keeps `$(...)` whole; its body is
# then read as commands, which errs toward a deny. Bash drops each `\<newline>` pair before it reads any of this, so a
# pair may stand in the word and before a `'`, `"`, or `(` after a `$`. The alternatives start with different
# characters, so a failed match backs out of the word once and no run of pairs is split two ways.
DELIMITER_WORD = re.compile(r"""((?:\\\n|'[^']*'|"(?:[^"\\]|\\.)*"|\\[^\n]|\$(?!(?:\\\n)*['"(])|[^\s;&|<>()'"\\$])+)(?![^\s;&|<>)])""",
                            re.DOTALL)
# `<<` that is not `<<<`, with line continuations allowed between the characters, as bash joins the lines first.
HEREDOC_OPERATOR = re.compile(r"<(?:\\\n)*<(?!(?:\\\n)*<)")
DELIMITER_PART = re.compile(r"""'([^']*)'|"((?:[^"\\]|\\.)*)"|\\(.)|([^'"\\]+)""", re.DOTALL)
# No command word, option, or refspec a guard looks at is this long, and the guards' flag pattern is
# quadratic in a word's length, so a cut word also keeps them fast.
LONG_WORD = 128
SEPARATORS = set("();|&\n")
BLANKS = set(" \t\r")
PLAIN = re.compile(r"[^ \t\r\n;&|()<>'\"\\$`]+")
DOUBLE_QUOTED = re.compile(r'[^"\\$`]*')
# What bash expands in a here-doc body whose delimiter has no quotes: an escaped character, `$(`, or a backtick.
BODY_EXPANSION = re.compile(r"\\.|\$\(|`", re.DOTALL)
# The flat read's patterns, where `$` and backticks are plain characters.
FLAT_PLAIN = re.compile(r"[^ \t\r\n;&|()<>'\"\\$]+|\$")
FLAT_DOUBLE_QUOTED = re.compile(r'[^"\\]*')
DOLLAR_QUOTED = re.compile(r"(?:[^'\\]|\\.)*'", re.DOTALL)
NAME = re.compile(r"\w*")
# Words that come before the command itself: wrappers and shell keywords.
WRAPPERS = {"builtin", "do", "then", "else", "elif", "if", "while", "until", "{", "!", "heavy"}
# Words that open a compound command, whose commands all write to its output, and the kind of each; and the words
# that close one, each only a group of its own kind. A `)` inside a `case` ends a pattern, not a group.
OPENERS = {"{": "{", "if": "if", "while": "loop", "until": "loop", "for": "loop", "select": "loop", "case": "case"}
CLOSERS = {"}": "{", "fi": "if", "done": "loop", "esac": "case"}
# Keywords that may come before an opener at the start of a command.
BEFORE_OPENER = {"do", "then", "else", "elif", "!", "time"}
# Wrappers with options, by the name without its directory, and the options that take a value: the next word, or
# the rest of a bundle of short options such as `-nuroot`.
OPTION_WRAPPERS = {
    "command": set(),  # -v and -V only print, which errs toward a deny
    "exec": {"-a"},
    "nohup": set(),
    "time": {"-f", "-o", "--format", "--output"},  # bash's keyword has only -p; /usr/bin/time has these
    "doas": {"-u", "-a", "-C"},
    "flock": {"-w", "--wait", "--timeout", "-E", "--conflict-exit-code"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t", "--user", "--group", "--host",
             "--prompt", "--chdir", "--chroot", "--close-from", "--command-timeout", "--other-user", "--role",
             "--type"},
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-a", "--argv0", "-P"},
    "nice": {"-n", "--adjustment"},
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
    "setsid": set(),
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"},
    "xargs": {"-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s", "--arg-file", "--delimiter", "--max-lines",
              "--max-args", "--max-procs", "--max-chars", "--process-slot-var"},
    "runuser": {"-u", "--user", "-g", "--group", "-G", "--supp-group", "-s", "--shell", "-w",
                "--whitelist-environment", "-c", "--command", "--session-command"},
    "su": {"-g", "--group", "-G", "--supp-group", "-s", "--shell", "-w", "--whitelist-environment", "-c", "--command",
           "--session-command"},
    "sg": set(),
    "chrt": {"-T", "--sched-runtime", "-P", "--sched-period", "-D", "--sched-deadline"},
    "taskset": set(),
    "watch": {"-n", "--interval", "-q", "--equexit"},
    "systemd-run": {"-u", "--unit", "-p", "--property", "-E", "--setenv", "-M", "--machine", "-H", "--host",
                    "--description", "--slice", "--uid", "--gid", "--nice", "--working-directory", "--on-active",
                    "--on-boot", "--on-startup", "--on-unit-active", "--on-unit-inactive", "--on-calendar",
                    "--timer-property", "--path-property", "--socket-property", "--service-type", "--expand-environment",
                    "--json", "--background"},
    "unshare": {"-S", "--setuid", "-G", "--setgid", "-R", "--root", "-w", "--wd", "--map-user", "--map-group",
                "--map-users", "--map-groups", "--propagation", "--setgroups", "-l", "--load-interp", "--monotonic",
                "--boottime"},
    "nsenter": {"-t", "--target", "-N", "--net-socket", "-S", "--setuid", "-G", "--setgid"},
    "setpriv": {"--reuid", "--regid", "--ruid", "--rgid", "--euid", "--egid", "--groups", "--inh-caps",
                "--ambient-caps", "--bounding-set", "--securebits", "--pdeathsig", "--selinux-label",
                "--apparmor-profile", "--landlock-access", "--landlock-rule", "--seccomp-filter", "--ptracer"},
    "strace": {"-o", "--output", "-e", "-p", "--attach", "-s", "--string-limit", "-u", "--user", "-E", "--env", "-I",
               "--interruptible", "-X", "--const-print-style", "-P", "--trace-path", "-a", "--columns", "-b",
               "--detach-on", "-O", "--summary-syscall-overhead", "-S", "--summary-sort-by", "-U", "--summary-columns",
               "--argv0", "--trace", "--signal", "--status", "--trace-fds", "--abbrev", "--verbose", "--raw", "--read",
               "--write", "--inject", "--fault", "--syscall-limit", "--decode-pids", "--kvm",
               "--stack-trace-frame-limit"},
    "ltrace": {"-o", "--output", "-e", "-p", "-s", "-u", "-a", "--align", "-n", "--indent", "-l", "--library", "-A",
               "-w", "--where", "-x", "-D", "--debug", "-F", "--config"},
    "script": {"-c", "--command", "-E", "--echo", "-I", "--log-in", "-O", "--log-out", "-B", "--log-io", "-T",
               "--log-timing", "-m", "--logging-format", "-o", "--output-limit"},
    "unbuffer": set(),
    "busybox": set(),
    "chroot": {"--userspec", "--groups"},
}
# Options whose value is optional and only ever attached, as in `-m/proc/1/ns/mnt` or `--net=FILE`; the rest of a
# bundle after one is its value.
OPTIONAL_VALUES = {
    "nsenter": {"-m", "--mount", "-u", "--uts", "-i", "--ipc", "-n", "--net", "-p", "--pid", "-C", "--cgroup", "-U",
                "--user", "-T", "--time", "-r", "--root", "-w", "--wd", "-W", "--wdns"},
    "unshare": {"-m", "--mount", "-u", "--uts", "-i", "--ipc", "-n", "--net", "-p", "--pid", "-U", "--user", "-C",
                "--cgroup", "-T", "--time", "--mount-proc", "--mount-binfmt", "--kill-child"},
    # strace's long options with an optional value; listed so that `--stack-trace` is not read as a prefix of
    # --stack-trace-frame-limit, which takes the next word.
    "strace": {"--quiet", "--decode-fds", "--stack-trace", "--daemonize", "--relative-timestamps",
               "--absolute-timestamps", "--syscall-times", "--strings-in-hex", "--tips"},
    "watch": {"-d", "--differences"},
    "script": {"-t", "--timing"},
}
# Each wrapper's long options, for the unambiguous prefix that GNU tools take.
LONG_OPTIONS = {w: [v for v in values | OPTIONAL_VALUES.get(w, set()) if v.startswith("--")]
                for w, values in OPTION_WRAPPERS.items()}
# Options whose value is a command line that the wrapper runs: env splits it into words and reads options in it too;
# the others hand it to a shell.
SCRIPT_OPTIONS = {"env": {"-S", "--split-string"}, "runuser": {"-c", "--command", "--session-command"},
                  "su": {"-c", "--command", "--session-command"}, "script": {"-c", "--command"}}
INLINE_PREFIX = {"env": "env "}
# Wrappers that take one more word after their options and before the command: a duration, a lock file, a group, a
# priority, a CPU mask, or a new root.
POSITIONAL = {"timeout", "flock", "sg", "chrt", "taskset", "chroot"}
# Wrappers that may take `-c COMMAND` right after that word.
DASH_C_AFTER_POSITIONAL = {"flock", "sg"}
# Wrappers that run no command word of their own, only the value of -c, and read options after their other words:
# su, and runuser unless -u gave the user, take a user and hand the words after it, `--` included, to the shell,
# which runs a `-c COMMAND` among them; script takes a log file.
NO_COMMAND = {"su", "runuser", "script"}
# Wrappers that hand all their remaining words to a shell as one command line.
RUNS_REST = {"watch"}
# Wrappers that join the words after their command with spaces, so a `;` or `|` in a word is shell syntax there; watch
# does not with -x, which runs the words without a shell.
JOINS_REST = {"watch", "sg"}
FD = re.compile(r"(?:\\\n)*(?:[0-9](?:[0-9]|\\\n)*|\{(?:\\\n)*[A-Za-z_](?:[A-Za-z0-9_]|\\\n)*\}(?:\\\n)*)")
# A word that starts with a command substitution; it may expand to nothing. Words reach _command_word cut,
# so only the start is checked.
SUBSTITUTION = re.compile(r"\$\(|`")
ASSIGNMENT_WORD = re.compile(r"\w+\+?=.*", re.DOTALL)
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
# Commands whose words _script reads as another command.
CARRIERS = SHELLS | {"eval", "ssh", "tailscale", "find", "env", "flock"}
# The start of a command word that names the user's or the running shell through a variable, such as `$SHELL -c`,
# `$0 -c`, `${BASH:-bash} -c`, or `${SHELL##*/} -c`. What follows an operator after the name does not change the shell
# the variable usually holds, and it may be cut at LONG_WORD, so only the start is matched.
SHELL_VARIABLE = re.compile(r"\$(?:SHELL|BASH|ZSH_NAME|ZSH_ARGZERO|0)\Z|\$\{(?:SHELL|BASH|ZSH_NAME|ZSH_ARGZERO|0)(?:\}\Z|[^\w}])")
SHELL_VALUE_OPTIONS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
# ssh options that take their value as the next word.
SSH_VALUE_LETTERS = set("BbcDEeFIiJLlmOoPpQRSWw")
FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}
# tailscale's global options before its subcommand that take their value as the next word.
TAILSCALE_VALUE_OPTIONS = {"--socket", "-socket"}
# How deep a command inside a command inside a command is still read; each level reads its text once more.
MAX_DEPTH = 8
# Text read again (a backtick body, a `bash -c` script, the words after `eval`, a here-doc, here-string, or piped
# text that a shell runs) counts against a budget of NESTED_SHARE times the command's length plus NESTED_EXTRA;
# past it, deeper commands go unread.
NESTED_SHARE = 2
NESTED_EXTRA = 4096
# The least a line of an unread here-doc body charges to the bodies' budget when it is read on its own, so many short
# lines cannot cost more than the budget allows.
LINE_COST = 16
# A longer command gets only the flat read. The longest of 15943 Bash commands from this box's transcripts
# (14 days to 14-10-2026) had 24904 characters.
NESTED_LIMIT = 256 * 1024
# A `|` or `|&` after a command, past blanks and line continuations; `||` is not a pipe. A `)` there ends a
# group, whose output may go into a pipe or a file after it.
PIPE_AFTER = re.compile(r"(?:[ \t\r]|\\\n)*(?:\|(?!(?:\\\n)*\|)|\))")
# A `&` that sends the command before it to the background: not `&&`, `&>`, or the `&` of `|&`.
BACKGROUND_AFTER = re.compile(r"(?:[ \t\r]|\\\n)*(?<![&|])&(?![&>])")
# A short nested command of plain words, such as most backtick bodies, needs no full scan.
SIMPLE = re.compile(r"[ \t]*[\w./:=@%+,-]+(?:[ \t]+[\w./:=@%+,-]+)*[ \t]*")


class _Word:
    """One word as it is read: its first LONG_WORD characters, whether it is a `name=` assignment, and its
    letters while it may be a flag bundle."""

    def __init__(self, start):
        self.parts, self.size, self.letters, self.bundle, self.assignment = [], 0, {}, None, None
        self.rest, self.start = None, start  # start: the word's offset in the text

    def add(self, text):
        if self.assignment is None:
            end = NAME.match(text).end()
            if end < len(text):
                self.assignment = text[end] == "=" and self.size + end > 0
        if self.rest is not None:
            self.rest.append(text)
        elif self.size + len(text) > LONG_WORD:
            self.rest = [text[LONG_WORD - self.size:]]
            self.parts.append(text[:LONG_WORD - self.size])
        else:
            self.parts.append(text)
        if self.bundle is None and self.size + len(text) >= 2:
            head = ("".join(self.parts) + text)[:2]
            self.bundle = head[0] == "-" and head[1] != "-"
        self.size += len(text)
        if self.bundle:
            self.letters.update(dict.fromkeys(text))

    def text(self):
        word = "".join(self.parts)
        if self.size > LONG_WORD and self.assignment:
            return "_=" + word
        if self.size > LONG_WORD and self.bundle:
            letters = "".join(c for c in self.letters if c != "-")
            if letters.isascii() and letters.isalpha():
                return "-" + letters
        return word

    def full(self):
        return "".join(self.parts) + "".join(self.rest or ())


def _end_lines(text, join):
    """Each line's text without surrounding blanks, mapped to the offsets where such lines start; and, for each
    line of several joined ones, the offset of the newline that ends it, or -1. With join, a line that ends in an odd
    run of backslashes continues in the next, as bash reads the delimiter line of a here-doc with no quotes."""
    ends, last, start, whole, first = {}, {}, 0, "", None
    for line in text.split("\n"):
        if join and (len(line) - len(line.rstrip("\\"))) % 2:
            whole, first = whole + line[:-1], start if first is None else first
        else:
            if first is not None:
                last[first] = start + len(line)
            ends.setdefault((whole + line).strip(), []).append(start if first is None else first)
            whole, first = "", None
        start += len(line) + 1
    if first is not None:  # the text ends inside a joined line
        ends.setdefault(whole.strip(), []).append(first)
        last[first] = -1
    return ends, last


def _joined(body):
    """The text of an unquoted here-doc body without its `\\<newline>` pairs, which bash removes before it expands the
    body, and the offsets in the result where a pair was cut. A backslash that another one escapes starts no pair."""
    out, cuts, at, size, k = [], [], 0, 0, body.find("\\\n")
    while k >= 0:
        j = k
        while j and body[j - 1] == "\\":
            j -= 1
        if (k - j) % 2 == 0:
            out.append(body[at:k])
            size += k - at
            cuts.append(size)
            at = k + 2
        k = body.find("\\\n", k + 2)
    out.append(body[at:])
    return "".join(out), cuts


def _backticks(text):
    """Offsets of the backticks in text that no backslash escapes."""
    out, i = [], text.find("`")
    while i >= 0:
        k = i
        while k > 0 and text[k - 1] == "\\":
            k -= 1
        if (i - k) % 2 == 0:
            out.append(i)
        i = text.find("`", i + 1)
    return out


def _closing_parens(text):
    """Each `(` offset mapped to the offset of the `)` that closes it, quotes ignored."""
    out, stack = {}, []
    for m in re.finditer(r"[()]", text):
        if m.group() == "(":
            stack.append(m.start())
        elif stack:
            out[stack.pop()] = m.start()
    return out


def _skip_pairs(text, k, blanks=False):
    """The index after the `\\<newline>` pairs at k, and after blanks between them when blanks is set. A loop, not a
    regex, so a long run of pairs is read once."""
    n = len(text)
    while k < n:
        if text.startswith("\\\n", k):
            k += 2
        elif blanks and text[k] in " \t":
            k += 1
        else:
            break
    return k


def _delimiter_word(text, k):
    """The match of DELIMITER_WORD for the word after `<<`, which starts at k: the optional `-` and the blanks before the
    word are skipped, with any `\\<newline>` pairs among them. A `-` that no word follows is part of the word, unless
    a pair comes after it, which leaves no word to read."""
    k = _skip_pairs(text, k)
    if text.startswith("-", k):
        after = _skip_pairs(text, k + 1, True)
        if m := DELIMITER_WORD.match(text, after):
            return m
        if "\\\n" in text[k + 1:after]:
            return None
    return DELIMITER_WORD.match(text, _skip_pairs(text, k, True))


def _delimiter(word):
    """The line that ends a here-doc started with `<<word`, and whether the word has a quote or a backslash, so bash
    does not expand the body. The line is the word with its quotes removed and its `\\<newline>` pairs dropped, as bash
    drops them before it reads the word; inside double quotes a backslash escapes only `$`, a backtick, `"`, a
    backslash, or a newline. None when nothing but such pairs is left."""
    out, quoted = [], False
    for single, double, escaped, plain in DELIMITER_PART.findall(word):
        if plain:
            out.append(plain)
        elif escaped != "\n":
            quoted = True
            out.append(single or escaped or re.sub(r'\\([$`"\\])|\\\n', lambda m: m.group(1) or "", double))
    return ("".join(out), quoted) if out or quoted else None


def plain_words(tokens):
    """tokens without redirections, their targets, and the file descriptor words right before them: the words the
    command gets, as bash takes redirections out before it runs it."""
    out, k = [], 0
    while k < len(tokens):
        t = tokens[k]
        if isinstance(t, Operator):
            k += 1 if _heredoc(t) else 2
        elif isinstance(t, _Fd) and k + 1 < len(tokens) and isinstance(tokens[k + 1], Operator):
            k += 1
        else:
            out.append(t)
            k += 1
    return out


def plain_full(tokens, words):
    """plain_words(tokens) with each word uncut, from words, the same command's words as segments(full=) gives them."""
    if len(words) != len(tokens):
        return plain_words(tokens)
    return plain_words([w if type(t) is str and w is not None else t for t, w in zip(tokens, words)])


def _heredoc(op):
    """Whether the redirection operator op starts a here-doc, whose delimiter the scan already took, so no word
    after it is its target."""
    return op.endswith("<<") and not op.endswith("<<<") and not isinstance(op, _UnreadHeredoc)


def _arg_indexes(tokens, words, j):
    """The indexes from j on of the words that the command passes as arguments: redirections and their targets
    left out."""
    while j < len(tokens):
        if words[j] is None:
            j += 1 if _heredoc(tokens[j]) else 2
        elif isinstance(tokens[j], _Fd) and j + 1 < len(tokens) and words[j + 1] is None:
            j += 1
        else:
            yield j
            j += 1


def _args(tokens, words, j):
    """The words from index j on that the command passes as arguments: redirections and their targets left out."""
    return [words[k] for k in _arg_indexes(tokens, words, j)]


def _remote(tokens, words, at):
    """The words of the command that `ssh` or `tailscale ssh` at index at runs on the remote host, or None
    for another command; an empty list when it runs the login shell."""
    name = tokens[at].rsplit("/", 1)[-1]
    if name == "tailscale":
        args = _arg_indexes(tokens, words, at + 1)
        at = next(args, len(tokens))
        while at < len(tokens) and tokens[at].startswith("-"):
            if tokens[at] in TAILSCALE_VALUE_OPTIONS:
                next(args, None)
            at = next(args, len(tokens))
        if tokens[at:at + 1] != ["ssh"]:
            return None
    elif name != "ssh":
        return None
    args = _args(tokens, words, at + 1)
    k = _ssh_options(args, 0)
    return args[_ssh_options(args, k + 1):]  # OpenSSH also reads options after the destination


def _ssh_options(args, k):
    """The index of the first word from k on that is not an ssh option or an option's value."""
    while k < len(args) and args[k].startswith("-") and args[k] != "-":
        opt = args[k]
        k += 1
        if opt == "--":
            break
        for at, letter in enumerate(opt[1:], 1):
            if letter in SSH_VALUE_LETTERS:
                k += at == len(opt) - 1  # `-p 22` and `-tp 22` take the next word; `-p22` does not
                break
    return k


def _shell_options(tokens, words, at):
    """For the shell at index at: the index of its first word after its options, or len(tokens), the indexes of
    its options, whether one is -c, and whether one is -s. bash takes redirections out of the words first, so
    they may come between the options and before the script."""
    args, options, dash_c, dash_s = _arg_indexes(tokens, words, at + 1), [], False, False
    j = next(args, len(tokens))
    while j < len(tokens) and tokens[j][:1] in "-+":
        options.append(j)
        if tokens[j] == "--":
            return next(args, len(tokens)), options, dash_c, dash_s
        takes = 1 if tokens[j] in SHELL_VALUE_OPTIONS else 0
        if re.fullmatch(r"[-+][a-zA-Z]+", tokens[j]):
            dash_c = dash_c or "c" in tokens[j]
            dash_s = dash_s or "s" in tokens[j]
            takes = tokens[j].count("o") + tokens[j].count("O")  # `-euo pipefail`: each o takes the next word
        for _ in range(takes):
            next(args, None)
        j = next(args, len(tokens))
    return j, options, dash_c, dash_s


def _script(tokens, words, position=None):
    """The command text a segment hands to `bash -c` and similar shells, to `eval`, to a remote host over
    `ssh`, to `find -exec`, or to `env -S` and `flock FILE -c`; None for other commands. words holds each token's full text, and None for
    an operator. position is Position.of(tokens), when the caller has it."""
    position = position or Position.of(tokens)
    if position.inline is not None:
        return _inline(position, tokens, words)
    at = position.found
    if at >= len(tokens) or words[at] is None:
        return None
    name = program(tokens[at])
    if name == "eval":
        return " ".join(_args(tokens, words, at + 1))
    remote = _remote(tokens, words, at)
    if remote is not None:
        return " ".join(remote) or None  # ssh joins its words, and the remote shell reads them again
    if name == "find":
        args, scripts, k = _args(tokens, words, at + 1), [], 0
        while k < len(args):
            if args[k] in FIND_EXEC:
                end = k + 1
                while end < len(args) and args[end] not in (";", "+"):
                    end += 1
                scripts.append(" ".join(shlex.quote(a) for a in args[k + 1:end]))
                k = end
            k += 1
        return "\n".join(scripts) or None
    if name not in SHELLS:
        return None
    j, _, dash_c, _ = _shell_options(tokens, words, at)
    if dash_c and j < len(tokens) and words[j] is not None:
        return words[j]
    return None


ENV_ESCAPES = {"t": "\t", "n": "\n", "r": "\r", "f": "\f", "v": "\v"}


# Characters of expanded env -S text that one command may read again, over all its env -S readings, at every level.
ENV_READING_BUDGET = 8192
# Wrappers that run their command with the environment they got, so the names assigned before them reach an env after
# them; the others, such as sudo, su, and systemd-run, may clear or replace it. A sudo with -E or --preserve-env passes it
# on too.
ENV_KEEPING = {"env", "nohup", "nice", "timeout", "time", "exec", "command", "setsid", "stdbuf", "ionice", "chrt",
               "taskset", "flock", "xargs", "strace", "ltrace", "unbuffer", "busybox", "setpriv", "nsenter", "unshare",
               "chroot"}
# Commands that put names in the environment of the commands after them.
ENV_COMMANDS = {"export", "declare", "typeset", "readonly", "set"}
# Characters that `${NAME}` expansions may add to an env -S value, or the value's own length if that is more.
ENV_EXPANSION_LIMIT = 1024
# An assignment word, `NAME=value` or `NAME+=value`, with an ASCII name as env reads it.
ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)", re.DOTALL)
ENV_VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def _env_split(text, known=None):
    """The words GNU `env -S` makes of text. It splits at blanks and reads quotes, but runs no shell, so `;` and `|`
    stay inside words. Outside quotes `\\_` splits; inside double quotes it is a space. `\\c` ends the text, and `#`
    at the start of a word starts a comment. Outside single quotes env expands `${NAME}` into the word, unsplit. known
    holds the names assigned before the command, which reach env's environment; any other name the hook reads as
    unset, which adds nothing, not even an empty word, except that `${SHELL}` and `${BASH}` stay as written, so
    `program` reads them as a shell. Expansions past ENV_EXPANSION_LIMIT read as unset too, so a value repeated many
    times cannot push the text past the budget of text read again."""
    known, added, limit = known or {}, 0, max(len(text), ENV_EXPANSION_LIMIT)
    out, word, quote, started, i = [], [], None, False, 0
    while i < len(text):
        c = text[i]
        if quote == "'":
            if c == "'":
                quote = None
            elif c == "\\" and text[i + 1:i + 2] in ("\\", "'"):
                word.append(text[i + 1])
                i += 1
            else:
                word.append(c)
        elif c == "\\" and i + 1 < len(text):
            e = text[i + 1]
            i += 1
            if e == "c":
                break
            if e == "_" and quote is None:
                if started:
                    out.append("".join(word))
                word, started = [], False
                i += 1
                continue
            word.append(" " if e == "_" else ENV_ESCAPES.get(e, e))
            started = True
        elif c == "$" and (m := ENV_VARIABLE.match(text, i)):
            if m.group(1) in known and added + len(known[m.group(1)]) <= limit:
                word.append(known[m.group(1)])
                added += len(known[m.group(1)])
                started = started or known[m.group(1)] != ""
            elif m.group(1) in ("SHELL", "BASH"):
                word.append(m.group())
                started = True
            i = m.end()
            continue
        elif quote == '"':
            if c == '"':
                quote = None
            else:
                word.append(c)
        elif c in " \t\n\r\f\v":
            if started:
                out.append("".join(word))
            word, started = [], False
        elif c == "#" and not started:
            break
        elif c in "'\"":
            quote, started = c, True
        else:
            word.append(c)
            started = True
        i += 1
    if started:
        out.append("".join(word))
    return out


def _inline(position, tokens, words, known=None):
    """The command line that a wrapper such as `env -S`, `flock FILE -c`, or watch runs, with the words after it, or
    None. env splits its text into words itself, and most wrappers pass later words to the shell as words, so those
    are quoted here and keep any `;` or `|` they hold; watch and sg join them with spaces instead."""
    k, cut, wrapper = position.inline
    if words[k] is None:
        return None
    joins = wrapper in JOINS_REST and not position.exec
    rest = [w if joins else shlex.quote(w) for w in _args(tokens, words, k + 1)]
    if wrapper == "env":
        return INLINE_PREFIX[wrapper] + " ".join([shlex.quote(w) for w in _env_split(words[k][cut:], known)] + rest)
    return INLINE_PREFIX.get(wrapper, "") + " ".join([words[k][cut:]] + rest)


class _Environment:
    """What every read of one command shares about its environment: the budget left for env -S readings, the names
    assigned so far and their values, which of them are exported, and whether `set -a` exports every one. A name
    that a subshell or a script assigned stays, so the readings err toward a deny."""

    def __init__(self):
        self.left = ENV_READING_BUDGET
        self.shell, self.exported, self.flagged, self.auto = {}, {}, set(), False


def _assign(word, env, export):
    """Records `NAME=value` or `NAME+=value` in env, exported when export is set, `set -a` is on, or NAME already is;
    False for another word."""
    if not (m := ASSIGNMENT.fullmatch(word)):
        return False
    name, plus, value = m.groups()
    value = (env.shell.get(name, "") if plus else "") + value
    env.shell[name] = value
    if export or env.auto or name in env.exported or name in env.flagged:
        env.exported[name] = value
    return True


def _note_exports(tokens, words, position, env):
    """Records in env what the command that just ended assigns or exports: its own `NAME=value` words when it has no
    command, the names after `export`, `declare -x`, and `typeset -x`, and the assignments after `readonly` and a
    `declare` or `typeset` without -x, which only set shell variables; `set -a` and `set +a` switch exporting every
    assignment."""
    at = position.found
    if at >= len(tokens):
        for word in _args(tokens, words, 0):
            _assign(word, env, False)
        return
    name = program(tokens[at])
    if name not in ENV_COMMANDS:
        return
    args = _args(tokens, words, at + 1)
    if name == "set":
        rest = iter(args)
        for arg in rest:
            # `-a`, or `-o allexport`, where the o ends a bundle and takes the next word
            if re.fullmatch(r"[-+][a-zA-Z]*a[a-zA-Z]*", arg) or (
                    re.fullmatch(r"[-+][a-zA-Z]*o", arg) and next(rest, None) == "allexport"):
                env.auto = arg[0] == "-"
    elif name == "export" or any(re.fullmatch(r"-[a-zA-Z]*x[a-zA-Z]*", arg) for arg in args):
        for arg in args:
            if arg[:1] != "-" and not _assign(arg, env, True) and NAME.fullmatch(arg):
                if arg in env.shell:
                    env.exported[arg] = env.shell[arg]
                else:
                    env.flagged.add(arg)  # exported while unset: a later assignment is exported too
    else:
        for arg in args:
            if arg[:1] != "-":
                _assign(arg, env, False)


def _env_reading(tokens, words, position, env):
    """The command line that `env -S` runs with the names in its environment expanded, or None. Those are the names
    assigned before env, the `NAME=value` arguments of an env before it, and the names exported earlier, as long as
    every wrapper before the env passes its environment on. A name in the value reads as unset in the plain reading,
    so this one can only add commands; it also sets each name that it read in front of the command line, because an
    env -S inside it expands them again. Its text counts against env's budget, and None comes back when it does not
    fit."""
    if position.inline is None or position.inline[2] != "env" or not position.keeps_env():
        return None
    k, cut, _ = position.inline
    if words[k] is None:
        return None
    named = {m[1] for m in ENV_VARIABLE.finditer(words[k][cut:])}
    if not named:
        return None
    assigned, walker = {}, Position()
    for token, word in zip(tokens, words):
        if walker.found is not None:
            break
        # A word of the kind that sets a name: before the command, or among the arguments of an env.
        if (word is not None and not walker.skip and ASSIGNMENT_WORD.fullmatch(word)
                and (walker.state == "scan" or walker.state == "options" and walker.wrapper == "env")):
            if walker.wrappers:
                name, _, value = word.partition("=")  # env splits at the first `=`, so `X+=a` sets the name `X+`
                assigned[name] = value
            elif m := ASSIGNMENT.fullmatch(word):
                base = assigned[m[1]] if m[1] in assigned else env.shell.get(m[1], "")
                assigned[m[1]] = (base if m[2] else "") + m[3]
        walker.feed(token)
    known = {name: assigned[name] if name in assigned else env.exported[name]
             for name in named if name in assigned or name in env.exported}
    if not known:
        return None
    piece = " ".join(f"{name}={shlex.quote(value)}" for name, value in known.items()) + " "
    piece += _inline(position, tokens, words, known)
    if len(piece) > env.left:
        return None
    env.left -= len(piece)
    return piece


def _output_text(tokens, words, at=None):
    """The text that `echo` or `printf` writes, as a shell reading it would see it closely enough: `\\n` is
    a new line, and printf's arguments each start a line. None for other commands. at is _command_word(tokens), when
    the caller has it."""
    at = _command_word(tokens) if at is None else at
    if at >= len(tokens) or words[at] is None:
        return None
    name, args = tokens[at].rsplit("/", 1)[-1], _args(tokens, words, at + 1)
    if name == "echo":
        while args and re.fullmatch(r"-[neE]+", args[0]):
            args = args[1:]
        text = " ".join(args)
    elif name == "printf":
        text = "\n".join(args[1:] if args[:1] == ["--"] else args)
    else:
        return None
    return text.replace("\\n", "\n")


# Operators that send the standard output elsewhere, unless a file descriptor other than 1 is written before them.
STDOUT_REDIRECTS = {">", ">>", ">|", ">&", "&>", "&>>"}


def _stdout_redirected(tokens, words):
    """Whether the command sends its standard output to a file or another descriptor, so no pipe gets it."""
    for k, token in enumerate(tokens):
        if words[k] is None and token in STDOUT_REDIRECTS:
            fd = tokens[k - 1] if k and words[k - 1] is not None and isinstance(tokens[k - 1], _Fd) else "1"
            if token.startswith("&") or fd == "1":
                return True
    return False


def _stdin_redirected(tokens, words):
    """Whether the command reads its standard input from a file, a here-doc, or a here-string, so no pipe reaches it."""
    for k, token in enumerate(tokens):
        if words[k] is None and token[:1] == "<":
            fd = tokens[k - 1] if k and words[k - 1] is not None and isinstance(tokens[k - 1], _Fd) else "0"
            if fd == "0" and not (token == "<&" and tokens[k + 1:k + 2] == ["0"]):
                return True
    return False


@functools.lru_cache(maxsize=1024)
def program(word):
    """The command name a command word runs, without its directory; `bash` for a shell named by a variable."""
    return "bash" if word[:1] == "$" and SHELL_VARIABLE.match(word) else word.rsplit("/", 1)[-1]


def _name(tokens, at):
    """The command name at index at without its directory, or None past the end."""
    return program(tokens[at]) if at < len(tokens) else None


def _reads_stdin_script(tokens, words, budget, depth=0, position=None):
    """Whether the command runs its standard input as a script: a shell with no -c and no script file, or
    with -s, also as a remote command, and `ssh` with no remote command. Reading remote text again may use
    what is left of budget, the command's NESTED_SHARE budget, but does not spend it, because the remote
    command is read again anyway as the command's script; past it the answer is no."""
    if not depth:
        budget = [budget[0]]
    position = position or Position.of(tokens)
    at = position.found
    if position.inline is not None:
        remote = [_inline(position, tokens, words) or ""]  # read again like a remote command
    elif at >= len(tokens) or words[at] is None:
        return False
    else:
        remote = _remote(tokens, words, at)
    if remote is not None:
        if not remote:
            return True
        joined = " ".join(remote)
        budget[0] -= len(joined)
        if depth + 1 >= MAX_DEPTH or budget[0] < 0:
            return False
        # ssh joins its words, and the remote shell reads them again, so `'bash -s'` is a shell too.
        return any(_reads_stdin_script(found, [None if isinstance(w, Operator) else w for w in found], budget, depth + 1)
                   for found in segments(joined, None, MAX_DEPTH, budget))
    if program(tokens[at]) not in SHELLS or "xargs" in position.wrappers:
        return False  # xargs hands its input to the shell as arguments, not as a script
    j, options, dash_c, dash_s = _shell_options(tokens, words, at)
    if any(tokens[k] in ("--version", "--help") or re.fullmatch(r"-[a-zA-Z]*n[a-zA-Z]*", tokens[k]) for k in options):
        return False  # -n reads the script without running it
    return not dash_c and (dash_s or not _args(tokens, words, j))


class _Feed(list):
    """What a command or group writes that a shell could run: texts, here-doc entries, and the feeds of the
    commands of a group, which a shell that reads the outer feed walks too. A here-doc entry is a plain list.
    An open group also has its kind, a value of OPENERS or `(`, stdin, the feed every command in it reads, and fn,
    the name of the function whose body it is, or None."""


class _Fd(str):
    """Digits written right before a redirection, as in `2>`, so they name a file descriptor; `2 >` is a word."""


class _Text:
    """One command string, with what every read of it shares: its results, spans, and lookup tables."""

    def __init__(self, text, spans, budget, top=False, full=None, bodies=None, env=None):
        self.text, self.n, self.spans, self.out, self.budget, self.full = text, len(text), spans, [], budget, full
        self.env = env if env is not None else _Environment()
        # The budget of unquoted here-doc bodies read for substitutions, and of all text read again inside them, apart
        # from budget, so bodies cannot leave a later `bash -c` unread. It allows the command's length plus
        # NESTED_EXTRA, half of what budget allows, so the two together stay near the hook's time.
        self.bodies = bodies if bodies is not None else [0]
        self.extras = []  # (text, span, depth) of each _env_reading
        self.top = top  # keep only the commands the string itself runs, not those inside them
        self._ends, self._ticks, self._parens = {}, None, None
        self.pipe_reach = None

    def ends(self, join):
        """_end_lines of the text, with the lines joined or not."""
        if join not in self._ends:
            self._ends[join] = _end_lines(self.text, join)
        return self._ends[join]

    def backtick_end(self, at):
        self._ticks = self._ticks if self._ticks is not None else _backticks(self.text)
        k = bisect.bisect_right(self._ticks, at)
        return self._ticks[k] if k < len(self._ticks) else -1

    def closing_paren(self, at):
        self._parens = self._parens if self._parens is not None else _closing_parens(self.text)
        return self._parens.get(at, self.n)


def segments(command, spans=None, depth=0, budget=None, full=None, bodies=None, env=None):
    """Token lists of the commands in a shell string. At a quote that never closes, the commands read
    up to there are returned, the open word included, because bash still runs the lines before it.
    A list passed as spans gets the (start, end) offsets of each command in the string, words uncut;
    a command from a `bash -c` script or `eval` gets the span of the command that runs it. A list passed
    as full gets each command's words uncut, with None for an operator, in the order of the result. env is the
    _Environment that the reads of one command share; a read without one starts its own."""
    n = len(command)
    if depth and n <= LONG_WORD and SIMPLE.fullmatch(command):
        tokens = command.split()
        if not CARRIERS.intersection(t.rsplit("/", 1)[-1] for t in tokens):
            if spans is not None:
                spans.append((n - len(command.lstrip()), len(command.rstrip())))
            if full is not None:
                full.append(tokens)
            return [tokens]
    budget = budget if budget is not None else [NESTED_SHARE * n + NESTED_EXTRA]
    bodies = bodies if bodies is not None else [n + NESTED_EXTRA]
    t = _Text(command, spans, budget, full=full, bodies=bodies, env=env)
    if not depth and n > NESTED_LIMIT:
        _scan(t, 0, depth, False, flat=True)  # two reads of a command this long could pass the hook timeout
        return t.out
    _scan(t, 0, depth, False)
    if not depth and ("$" in command or "`" in command):
        # Also read the command flat, as before nested commands were read, so every command that read
        # found is still checked when a nested read ends a substitution in the wrong place.
        _scan(t, 0, depth, False, flat=True)
    # The expanded env -S readings come last, on a small budget of their own, so the commands before them, and what
    # a hook that reads them in order spends on them, stay as without them.
    for piece, span, at in t.extras:
        sub = [] if spans is not None else None
        sub_full = [] if full is not None else None
        found = segments(piece, sub, at + 1, None, sub_full, env=t.env)
        t.out.extend(found)
        if spans is not None:
            spans.extend([span] * len(found))
        if full is not None:
            full.extend(sub_full)
    return t.out


def _scan(t, i, depth, stop, flat=False):
    """Read t.text from offset i into t.out. With stop, the read is the body of a `$(`: it ends at the
    `)` that closes it, and returns that offset; otherwise it reads to the end. With flat, the read is the
    one this module made before it read nested commands: a `(` or `)` splits the command anywhere outside
    quotes, double-quoted text is plain text, and nothing is read a second time."""
    text, n, out, spans = t.text, t.n, t.out, t.spans
    current, words, word, pending, heredocs = [], [], None, [], None
    # Inside a `$(...)`: open parens, and open `case` commands, whose patterns end in a `)` of their own.
    start, last, parens, cases = None, i, 0, 0
    # Only a `$(` body needs to know where the command is, to tell the `)` of a `case` pattern from its own.
    position = Position() if stop else None
    # What a `|` sends to the next command, as a list of texts and here-doc entries a shell could run, and the
    # same for the command or group that ended last. groups holds such a list per open `( ... )` or `{ ...; }`.
    # A group's list holds the lists of its commands without copying them, so deep nesting stays linear; only a
    # shell that reads them walks them.
    piped, last_feed, after_pipe, groups = _Feed(), _Feed(), False, []
    # Whether last_feed still waits for the separator after it: a `|` hands it to the next command, any other
    # separator adds it to the enclosing group's output. Only output that leaves its pipeline joins the group.
    unjoined = False
    # Backtick bodies as (begin, end) offsets, and the texts of `bash -c`, `eval`, `ssh`, `find -exec`,
    # here-docs, here-strings, and piped text that a shell runs, with their spans. A pending here-doc: its
    # delimiter, whether bash expands its body, and its command's tokens, words, and span.
    inner, scripts, inner_until = [], [], 0
    walked = {}  # the feeds that a shell already reads, by id
    # The functions defined so far, each with what its body writes, and the name whose body the next group is.
    functions, defining = {}, None
    # What each shell that reads its standard input reads, with its span. They are walked at the end, once each
    # group's own redirections are known: a group whose input comes from a file, here-doc, or here-string reads
    # that instead of its stdin.
    reads = []
    # The `( ... )` group that just closed, whose redirections come in the command after its `)`.
    closing = None
    ended = None
    # The first `<<` whose delimiter word the scan leaves unread: its offset, and its command's span once it ends.
    unread_at, unread_span = None, None
    # Position.of(current), once the command has ended and a read asks for it.
    cmd_position = None

    def where():
        nonlocal cmd_position
        cmd_position = cmd_position if cmd_position is not None else Position.of(current)
        return cmd_position

    def finish():
        nonlocal word, cases
        if word is not None:
            token = word.text()
            if stop:
                if token in ("case", "esac") and position.at_command():
                    cases += 1 if token == "case" else -(cases > 0)
                position.feed(token)
            current.append(token)
            # Strings only: a list of a million word objects keeps the garbage collector busy.
            words.append(token if word.rest is None else word.full())
            word = None

    def operator(token, fd="", kind=None):
        kind = kind or Operator
        current.append(kind(fd + token))
        if stop:
            position.feed(kind(token))
        words.append(None)

    def end_command(end):
        nonlocal start, unread_span, ended
        span = ended = (end, end) if start is None else (start, last)
        if t.top and depth:
            start = None
            return
        out.append([tok if w is None else w for tok, w in zip(current, words)] if t.top else current)
        if spans is not None:
            spans.append(span)
        if t.full is not None:
            t.full.append(list(words))
        if pending and pending[-1][2][0] is current:
            pending[-1][2][2] = span
        if unread_at is not None and unread_span is None:
            unread_span = span
        script = _script(current, words, where()) if current and not flat else None
        if script is not None:
            scripts.append((script, span))
            if (not t.top and depth < MAX_DEPTH and script.startswith(INLINE_PREFIX["env"])
                    and (extra := _env_reading(current, words, where(), t.env))):
                t.extras.append((extra, span, depth))
        if current and not flat and not t.top:
            _note_exports(current, words, where(), t.env)
        # No script found at MAX_DEPTH is ever read, so the checks there cannot change the result. They are
        # skipped, because each would start a new read of the next ssh level, and the work would multiply per level.
        if current and not flat and not t.top:
            open_groups()
        if current and not flat and not t.top and depth < MAX_DEPTH:
            _stdin_scripts(span)
        start = None

    def here_strings():
        return [words[k + 1] for k in range(len(current) - 1) if current[k] == "<<<" and words[k] is None]

    def _stdin_scripts(span):
        # A here-string, or what a pipe sends into this command, that this command runs as a script.
        strings = here_strings()
        if not strings and not piped:
            return
        if not _reads_stdin_script(current, words, t.budget, position=where()):
            return
        scripts.extend((s, span) for s in strings if s is not None)
        if not _stdin_redirected(current, words):
            reads.append((piped, span))

    def walk(feed, span):
        # A feed can hold the same inner feed twice, as in `( (echo x) 2>&1 )`, and every shell in a group reads
        # the group's feed, so each feed is walked once per read; walked keeps them alive, so no id is reused.
        stack = [feed] if id(feed) not in walked else []
        walked.setdefault(id(feed), feed)
        while stack:
            for item in stack.pop():
                if isinstance(item, str):
                    scripts.append((item, span))
                elif isinstance(item, _Feed):
                    if id(item) not in walked:
                        walked[id(item)] = item
                        stack.append(item)
                elif not item[3]:
                    item[3] = True  # a here-doc body reaches the shell through cat
                    scripts.extend((body, span) for body in item[4])  # bodies read before this shell
                    item[4].clear()

    def feed():
        # What the command that just ended writes to its standard output, as far as a shell could run it.
        if _stdout_redirected(current, words):
            return _Feed()
        at = where().found
        if at >= len(current):
            # Redirections alone right after a group, as in `( ... ) 2>/dev/null`, pass the group's output on.
            return last_feed if unjoined else _Feed()
        text = _output_text(current, words, at)
        if text:
            return _Feed([text])
        name = _name(current, at)
        passed = passed_on(at, name)
        # A function may shadow `cat` or `tee`; reading both what it writes and what they pass on errs toward a deny.
        return passed if name not in functions else _Feed([functions[name], passed])

    def passed_on(at, name):
        # What `cat` or `tee` passes on from its input; nothing for other commands.
        if name == "tee":
            return piped
        if name != "cat":
            return _Feed()
        own = redirected_input()
        if own:
            return own
        reads_pipe = all(a.startswith("-") for a in _args(current, words, at + 1))
        return piped if reads_pipe and not _stdin_redirected(current, words) else _Feed()

    def redirected_input():
        # The here-doc and here-strings of the command that just ended, which it reads instead of a pipe.
        own = _Feed([heredocs] if heredocs is not None and heredocs[0] is current else [])
        own += [s for s in here_strings() if s is not None]
        return own

    def escaped(k):
        # Whether an odd run of backslashes ends right before offset k.
        j = k
        while j and text[j - 1] == "\\":
            j -= 1
        return (k - j) % 2 == 1

    def open_group(kind):
        # A group's stdin holds what a pipe sends into it, or its enclosing group's stdin, in a feed of its own, so
        # a redirection on the group can replace it for every command inside.
        nonlocal defining, piped
        group = _Feed()
        group.kind, group.fn, defining = kind, defining, None
        group.stdin = _Feed([piped if after_pipe else groups[-1].stdin if groups else _Feed()])
        groups.append(group)
        piped = group.stdin

    def closes():
        # Whether the command that just ended starts by closing the innermost open group.
        return bool(current) and words[0] is not None and bool(groups) and CLOSERS.get(current[0]) == groups[-1].kind

    def open_groups():
        # Opens the groups that the command that just ended starts, before a shell in it reads its input.
        nonlocal defining
        if closes():
            return
        k, count = 0, len(groups)
        if current[0] == "function" and len(current) > 1 and words[0] is not None:
            defining, k = current[1], 2
        while k < len(current) and words[k] is not None:
            if current[k] in OPENERS:
                open_group(OPENERS[current[k]])
            elif current[k] not in BEFORE_OPENER:
                break
            if current[k] in ("for", "select", "case"):
                break  # the words after it are its own
            k += 1
        if len(groups) == count:
            defining = None

    def close_groups():
        # Closes the groups that the command that just ended starts by closing, and returns what the outermost of
        # them writes, or None. A redirection of the command's input replaces that group's stdin.
        k, found, group = 0, None, None
        while k < len(current) and words[k] is not None and groups and CLOSERS.get(current[k]) == groups[-1].kind:
            if found is not None:
                groups[-1].append(found)  # `done }`: the inner group's output joins the outer one
            group = groups.pop()
            found = defined(group)
            k += 1
        if group is not None and _stdin_redirected(current, words):
            group.stdin[:] = redirected_input()
        return found

    def settle_closing():
        # The command right after a `)` may redirect the group's input: `( bash ) < f`.
        nonlocal closing
        if closing is not None and current and where().found >= len(current) and _stdin_redirected(current, words):
            closing.stdin[:] = redirected_input()
        closing = None

    def defined(group):
        # A function's body runs only when the function is called, so its definition writes nothing.
        if group.fn is None:
            return group
        functions[group.fn] = group
        return _Feed()

    def track_pipe(c, i):
        # Runs at each separator c at offset i, after the command before it ended.
        nonlocal piped, last_feed, after_pipe, unjoined, defining, closing
        settle_closing()
        # The second `|` of `||` ends an empty command, also when a line continuation splits the two; a `|` after
        # an odd run of backslashes is a word.
        nxt = i + 1
        while text.startswith("\\\n", nxt):
            nxt += 2
        pipe = c == "|" and text[nxt:nxt + 1] != "|"
        prev = i - 1
        while prev > 0 and text[prev] == "\n" and escaped(prev):
            prev -= 2
        if pipe and prev >= 0 and text[prev] == "|":
            pipe = escaped(prev)
        if current:
            found = close_groups()
            if found is not None:
                last_feed = _Feed() if _stdout_redirected(current, words) else found
            else:
                last_feed = feed()
                if t.pipe_reach is not None and not depth and not _stdout_redirected(current, words):
                    t.pipe_reach[0][ended] = last_feed
            unjoined = True
        if unjoined and not pipe:
            if groups:
                groups[-1].append(last_feed)
            unjoined = False
        if c == "(":
            open_group("(")
            name = current[-1] if len(current) == 1 or (current[:1] == ["function"] and len(current) == 2) else None
            if name is not None and words[-1] is not None and text[i + 1:i + 64].lstrip(" \t").startswith(")"):
                defining = name  # `name ()`: the group after it is the body
        elif c == ")" and groups and groups[-1].kind != "case":
            closing = groups.pop()
            last_feed, unjoined = defined(closing), True
        if pipe:
            piped, after_pipe, unjoined = last_feed, True, False
            if t.pipe_reach is not None and not depth:
                t.pipe_reach[1].append(last_feed)
        elif current or not after_pipe or c not in "&\n(":
            # An empty command right after `|`, such as the `&` of `|&`, a line break, or a `(`, keeps the pipe. Any
            # other command in a group reads what the group reads.
            piped, after_pipe = groups[-1].stdin if groups else _Feed(), False

    def expand_body(begin, end):
        # bash runs each `$(...)` and backtick body in an unquoted here-doc body, as in a double-quoted string, and
        # then a shell that reads the body gets the expanded text. This reads those substitutions and returns that
        # text, with `$()` for each substitution, whose output is not known, and the backslash gone before `$`, a
        # backtick, a backslash, or a newline. A shell's read of the result does not read a substitution again,
        # and it reads one that the backslashes hid, as the shell does. The body is read as a text of its own, so a
        # `$(` it leaves open ends at the end line, as in bash, and it counts against the bodies' budget, so many
        # bodies cannot multiply the work. bash drops each `\<newline>` pair before all of this, so `$\<newline>(` is
        # a substitution. Past that budget the body comes back as it is. A command at MAX_DEPTH reads the bodies'
        # substitutions at its own level, as it reads a `$(` of its own, because the shell runs them.
        raw = text[begin:end]
        if t.bodies[0] < end - begin:
            return raw
        joined, cuts = _joined(raw) if "\\\n" in raw else (raw, ())
        m = BODY_EXPANSION.search(joined)
        if m is None:
            return joined
        t.bodies[0] -= end - begin
        body = _Text(joined, [] if spans is not None else None, t.bodies, t.top,
                     [] if t.full is not None else None, t.bodies, t.env)
        expanded, at = [], 0
        while m:
            expanded.append(joined[at:m.start()])
            at = m.end()
            if m.group() == "$(":
                at = _scan(body, at, min(depth + 1, MAX_DEPTH), True) + 1
                expanded.append("$()")
            elif m.group() == "`":
                close = body.backtick_end(at - 1)
                close = body.n if close < 0 else close
                if not read_body_piece(body, at, close):
                    at -= 1
                    break
                at = close + 1
                expanded.append("$()")
            else:
                escaped = m.group()[1]
                expanded.append(escaped if escaped in "$`\\" else "" if escaped == "\n" else m.group())
            m = BODY_EXPANSION.search(joined, at) if at < body.n else None
        expanded.append(joined[at:])
        out.extend(body.out)
        if spans is not None:
            # Offsets in the joined text count the pairs cut before them, two characters each.
            spans.extend((begin + a + 2 * bisect.bisect_right(cuts, a), begin + b + 2 * bisect.bisect_left(cuts, b))
                         for a, b in body.spans)
        if t.full is not None:
            t.full.extend(body.full)
        return "".join(expanded)

    def read_body_piece(body, begin, end):
        # A backtick body inside a here-doc body, read on the bodies' budget; False once that budget is spent.
        piece = body.text[begin:end]
        if not piece or piece.isspace():
            return True
        t.bodies[0] -= len(piece)
        if t.bodies[0] < 0:
            return False
        sub = [] if body.spans is not None else None
        sub_full = [] if body.full is not None else None
        body.out.extend(segments(piece, sub, min(depth + 1, MAX_DEPTH), t.bodies, sub_full, t.bodies, t.env))
        if sub is not None:
            body.spans.extend((a + begin, b + begin) for a, b in sub)
        if sub_full is not None:
            body.full.extend(sub_full)
        return True

    def read_unread_body(at, stop_at, span):
        # The body of a here-doc whose delimiter the scan leaves unread is read as commands, which errs toward a deny,
        # unless a stray quote in it swallows the commands after the body. So each line after the command's line is
        # also read on its own, where a quote ends with its line, on the bodies' budget.
        nl = text.find("\n", at, stop_at)
        for line in text[nl + 1:stop_at].split("\n") if nl >= 0 else ():
            if not line or line.isspace():
                continue
            t.bodies[0] -= max(len(line), LINE_COST)
            if t.bodies[0] < 0:
                break
            sub = [] if spans is not None else None
            sub_full = [] if t.full is not None else None
            found = segments(line, sub, depth + 1, t.bodies, sub_full, t.bodies, t.env)
            out.extend(found)
            if t.full is not None:
                t.full.extend(sub_full)
            if spans is not None:
                spans.extend([span] * len(found))

    def substitution(begin, end):
        nonlocal inner_until
        # A backtick body inside one already found is read when that one is.
        if begin >= inner_until:
            inner.append((begin, end))
            inner_until = end

    closed = False
    while i < n:
        c = text[i]
        if start is None and c not in BLANKS and c != "#" and not text.startswith("\\\n", i) and (
                c not in SEPARATORS or text.startswith("&>", i)):
            start = i
        if c in BLANKS:
            finish()
            i += 1
        elif c == "&" and text.startswith(">", i + 1):
            # `&>` and `&>>` redirect; they do not end the command.
            finish()
            j = i + 2 + (text.startswith(">", i + 2))
            operator(text[i:j])
            i = last = j
        elif c in SEPARATORS:
            finish()
            if stop and c == ")" and parens == 0 and cases == 0:
                closed = True
                break
            if stop and c == "(":
                parens += 1
            elif stop and c == ")" and parens:
                parens -= 1  # with parens at 0 and a `case` open, the `)` ends a pattern
            end_command(i)
            if not flat and not t.top:
                track_pipe(c, i)
            current, words, cmd_position = [], [], None
            position = Position() if stop else None
            i += 1
            if c == "\n" and pending:
                # Here-doc bodies start on the next line; bash reads them in order.
                for delimiter, expands, heredocs in pending:
                    ends, continued = t.ends(expands)
                    found = ends.get(delimiter, [])
                    k = bisect.bisect_left(found, i)
                    if k == len(found):
                        break  # unterminated: read the rest as commands, which errs toward a deny
                    body = expand_body(i, found[k]) if expands and not flat and not t.top else text[i:found[k]]
                    if not flat and not t.top and depth < MAX_DEPTH and heredocs[2] is not None:
                        if heredocs[3] is None:  # once per command, however many here-docs it has
                            heredocs[3] = _reads_stdin_script(heredocs[0], heredocs[1], t.budget)
                        if heredocs[3]:
                            scripts.append((body, heredocs[2]))
                        else:
                            heredocs[4].append(body)  # a shell that a group pipes it to may come later
                    nl = continued.get(found[k], text.find("\n", found[k]))
                    i = n if nl < 0 else nl + 1
                pending = []
        elif c in "<>" and text.startswith("(", i + 1) and not flat and depth + 1 < MAX_DEPTH:
            # `<(...)` and `>(...)`: bash runs the body as commands, and the word is the name of a pipe.
            word = word if word is not None else _Word(i)
            end = _scan(t, i + 2, depth + 1, True)
            word.add(text[i:end + 1])
            i = last = min(end + 1, n)
        elif c in "<>":
            fd = ""
            # Unquoted digits right before it, line continuations aside, name the file descriptor: `2>`; so does
            # `{NAME}`, a descriptor bash picks and stores in NAME.
            adjacent = word is not None and FD.fullmatch(text, word.start, i)
            if t.top and adjacent:
                fd, word = text[word.start:i].replace("\\\n", ""), None
            finish()
            if adjacent and not t.top:
                current[-1], words[-1] = _Fd(current[-1]), _Fd(words[-1])
            if op := HEREDOC_OPERATOR.match(text, i):
                m = _delimiter_word(text, op.end())
                delimiter = _delimiter(m.group(1)) if m else None
                if delimiter:
                    if not pending or pending[-1][2][0] is not current:
                        # The command's tokens, words, span, verdict, and the bodies read while no shell read them.
                        heredocs = [current, words, None, None, []]
                    pending.append((delimiter[0], not delimiter[1], heredocs))
                    operator("<<", fd)
                    i = last = m.end()
                    continue
                kind = _UnreadHeredoc
                unread_at = i if unread_at is None else unread_at
            else:
                kind = None
            j, size = i, 0
            while j < n:
                k = j
                while text.startswith("\\\n", k):
                    k += 2  # a line continuation inside the operator
                if k >= n or text[k] not in "<>":
                    break
                j, size = k + 1, size + 1
            if j < n and text[j] in "&|" and size == 1:
                j += 1  # `>&`, `<&`, and `>|` are one operator
            operator(text[i:min(j, i + LONG_WORD)].replace("\\\n", ""), fd, kind)
            i = last = j
        elif text.startswith("\\\n", i):
            i += 2  # a line continuation joins the two lines, also between words
        elif c == "#" and word is None:
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
        else:
            word = word if word is not None else _Word(i)
            if flat and c == "$":
                if text.startswith("$$", i):
                    word.add("$$")
                    i += 2
                elif text.startswith("$'", i):
                    m = DOLLAR_QUOTED.match(text, i + 2)
                    if m is None:
                        word.add(text[i + 2:])
                        last = n
                        break
                    word.add(text[i + 2:m.end() - 1])
                    i = m.end()
                elif text.startswith('$"', i):
                    i += 1
                else:
                    word.add("$")
                    i += 1
            elif flat and c == "`":
                m = FLAT_PLAIN.match(text, i)
                word.add(m.group())
                i = m.end()
            elif c == "$":
                k = i + 1
                while text.startswith("\\\n", k):
                    k += 2  # bash joins the lines before it reads what follows the `$`
                nxt = text[k:k + 1]
                if nxt == "$":
                    word.add("$$")  # the process id, so a quote right after it is a plain quote
                    i = k + 1
                elif nxt == "'":
                    # Inside `$'...'` a backslash escapes the next character, `\'` included.
                    m = DOLLAR_QUOTED.match(text, k + 1)
                    if m is None:
                        word.add(text[k + 1:])
                        last = n
                        break
                    word.add(text[k + 1:m.end() - 1])
                    i = m.end()
                elif nxt == '"':
                    i = k  # `$"..."` is a double-quoted string
                elif nxt == "(" and depth + 1 < MAX_DEPTH:
                    # bash reads the body as commands up to the `)` that closes it; the word goes on after it.
                    end = _scan(t, k + 1, depth + 1, True)
                    word.add(text[i:end + 1])
                    i = end + 1
                else:
                    word.add("$")  # past MAX_DEPTH, a `(` right after it splits the command, so the body is still read
                    i += 1
            elif c == "`":
                j = t.backtick_end(i)
                if j < 0:
                    word.add(text[i:])
                    substitution(i + 1, n)
                    last = n
                    break
                word.add(text[i:j + 1])
                substitution(i + 1, j)
                i = j + 1
            elif c == "\\":
                word.add(text[i + 1:i + 2])
                i += 2
            elif c == "'":
                close = text.find("'", i + 1)
                if close < 0:
                    word.add(text[i + 1:])
                    last = n
                    break
                word.add(text[i + 1:close])
                i = close + 1
            elif c == '"':
                i += 1
                while True:
                    m = (FLAT_DOUBLE_QUOTED if flat else DOUBLE_QUOTED).match(text, i)
                    word.add(m.group())
                    i = m.end()
                    if i >= n:
                        break
                    if text[i] == '"':
                        i += 1
                        break
                    if text.startswith("$(", i):
                        # bash reads the body as commands, with its own quotes, up to the `)` that closes it.
                        end = _scan(t, i + 2, depth + 1, True) if depth + 1 < MAX_DEPTH else t.closing_paren(i + 1)
                        word.add(text[i:end + 1])
                        i = end + 1
                        continue
                    if text[i] == "$":
                        word.add("$")
                        i += 1
                        continue
                    if text[i] == "`":
                        j = t.backtick_end(i)
                        j = n - 1 if j < 0 else j
                        substitution(i + 1, j)
                        word.add(text[i:j + 1])
                        i = j + 1
                        continue
                    nxt = text[i + 1:i + 2]
                    if nxt in ('"', "\\", "$", "`"):
                        word.add(nxt)
                        i += 2
                    elif nxt == "\n":
                        i += 2
                    else:
                        word.add("\\")
                        i += 1
            else:
                m = (FLAT_PLAIN if flat else PLAIN).match(text, i)
                word.add(m.group())
                i = m.end()
            last = min(i, n)
    finish()
    end = i if closed else n
    end_command(end)
    if not flat and not t.top:
        settle_closing()
        close_groups()
        for piece, span in reads:
            walk(piece, span)
    if depth < MAX_DEPTH and not t.top:
        nested = [(text[b:e], b, None) for b, e in inner] + [(script, None, span) for script, span in scripts]
        for piece, begin, span in nested:
            if not piece or piece.isspace():
                continue
            t.budget[0] -= len(piece)
            if t.budget[0] < 0:
                break
            sub = [] if spans is not None else None
            sub_full = [] if t.full is not None else None
            found = segments(piece, sub, depth + 1, t.budget, sub_full, t.bodies, t.env)
            out.extend(found)
            if t.full is not None:
                t.full.extend(sub_full)
            if spans is not None and begin is not None:
                spans.extend((a + begin, b + begin) for a, b in sub)
            elif spans is not None:
                spans.extend([span] * len(found))
        if unread_span is not None and not flat:
            read_unread_body(unread_at, end, unread_span)
    return end


def _option_value(wrapper, option):
    """For an option of wrapper: the option that takes a value, or None; whether its value is the next word; and
    the offset in the option where an attached value starts, or None."""
    values, optional = OPTION_WRAPPERS[wrapper], OPTIONAL_VALUES.get(wrapper, ())
    if option.startswith("--"):
        name, eq, _ = option.partition("=")
        if name not in values and name not in optional:
            matches = [v for v in LONG_OPTIONS[wrapper] if v.startswith(name)]
            if len(matches) == 1:
                name = matches[0]  # GNU tools take an unambiguous prefix: `--split` is `--split-string`
        if name not in values:
            return None, False, None
        return (name, False, option.index("=") + 1) if eq else (name, True, None)
    for k, letter in enumerate(option[1:], 1):
        if "-" + letter in optional:
            return None, False, None
        if "-" + letter in values:
            return ("-" + letter, True, None) if k == len(option) - 1 else ("-" + letter, False, k + 1)
    return None, False, None


def _has_option(wrapper, option, long_name, shortest_prefix, letter):
    """Whether an option of `wrapper` is `-letter` or `long_name`, alone, in a bundle of short options, or as a long
    prefix of at least `shortest_prefix` characters; a short option that takes a value ends the bundle."""
    if option.startswith("--"):
        name = option.partition("=")[0]
        return len(name) >= shortest_prefix and long_name.startswith(name)
    for c in option[1:]:
        if c == letter:
            return True
        if "-" + c in OPTION_WRAPPERS[wrapper] or "-" + c in OPTIONAL_VALUES.get(wrapper, ()):
            return False
    return False


def _preserves_env(option):
    """Whether a sudo option is -E or --preserve-env; `--preserve-env=LIST` counts, as the names it lists may include
    one the hook reads."""
    return _has_option("sudo", option, "--preserve-env", 5, "E")  # `--pr` could be --prompt


def _watch_exec(option):
    return _has_option("watch", option, "--exec", 4, "x")  # `--e` could be --errexit or --equexit


class Position:
    """Finds the command a segment runs, one token at a time and in constant time per token: it comes after
    redirections, VAR=value words, wrappers such as sudo and timeout with their options, and shell keywords.
    at_command() says whether the next token would be the command. found is its index once seen; wrappers holds
    the wrappers with options before it; inline is (index, offset) of a value that the wrapper runs as a command
    line, such as the one of `env -S` or `flock FILE -c`."""

    def __init__(self):
        self.state, self.wrapper, self.skip, self.n = "scan", None, 0, 0
        self.found, self.wrappers, self.inline = None, [], None
        self.preserving = set()  # the indexes in wrappers of the sudo commands that got -E or --preserve-env
        self.user = False  # whether -u gave runuser its user
        self.exec = False  # whether watch got -x
        self.pending = None

    @classmethod
    def of(cls, tokens):
        position = cls()
        for t in tokens:
            if position.found is not None:
                break
            position.feed(t)
        if position.found is None and position.state == "subcommand":
            position.found = position.pending
        if position.found is None:
            position.found = len(tokens) - (position.state == "digit")
        return position

    def keeps_env(self):
        """Whether every wrapper before the command passes its environment on."""
        return all(w in ENV_KEEPING or k in self.preserving for k, w in enumerate(self.wrappers))

    def at_command(self):
        return not self.skip and (self.state in ("scan", "flock")
                                  or (self.state == "options" and self.wrapper not in POSITIONAL))

    def run(self, k, cut):
        # A wrapper option or argument whose value is the command line it runs.
        self.inline, self.found, self.state = (k, cut, self.wrapper), k, "done"

    def feed(self, t):
        i = self.n
        self.n += 1
        if self.state == "done":
            return  # the command is found, and what follows changes nothing
        if self.state in ("value", "options", "positional", "flock", "subcommand"):
            # bash takes redirections out of the words first: `env -S >f cmd` runs `env -S cmd`, `sudo >f -u root
            # cmd` runs `sudo -u root cmd`, and in `sudo -u >f root cmd` the option still gets root.
            if isinstance(t, Operator):
                self.skip += not _heredoc(t)
                return
            if isinstance(t, _Fd):
                return  # the file descriptor of the redirection that follows
        if self.skip:
            self.skip -= 1
            return
        if self.state == "value":
            self.run(i, 0)
            return
        if self.state == "options":
            if t == "--" and self.wrapper in NO_COMMAND and not self.user:
                pass
            elif t == "--":
                self.state = ("positional" if self.wrapper in POSITIONAL else
                              "value" if self.wrapper in RUNS_REST else "scan")
            elif t.startswith("-") and t != "-":
                name, nxt, cut = _option_value(self.wrapper, t)
                if name in SCRIPT_OPTIONS.get(self.wrapper, ()):
                    if nxt:
                        self.state = "value"
                    else:
                        self.run(i, cut)
                else:
                    if self.wrapper == "sudo" and _preserves_env(t):
                        self.preserving.add(len(self.wrappers) - 1)
                    self.user = self.user or name in ("-u", "--user")
                    self.exec = self.exec or (self.wrapper == "watch" and _watch_exec(t))
                    self.skip = int(nxt)
            elif t == "-":
                pass  # su's login shell, env's -i
            elif self.wrapper in NO_COMMAND and not self.user:
                pass  # a user, a word for su's shell, or script's log file
            elif self.wrapper in RUNS_REST:
                self.run(i, 0)
            else:
                self.n -= 1
                self.state = "positional" if self.wrapper in POSITIONAL else "scan"
                self.feed(t)
        elif self.state == "subcommand":
            if t == "exec":
                self.state, self.wrapper = "positional", "direnv"
            elif not t.startswith("-"):
                self.state, self.found = "done", self.pending
        elif self.state == "positional":
            self.state = "flock" if self.wrapper in DASH_C_AFTER_POSITIONAL else "scan"  # t is the word before it
        elif self.state == "flock":
            if t in ("-c", "--command"):
                self.state = "value"
            elif self.wrapper == "sg":
                self.run(i, 0)  # sg hands its word after the group to a shell
            else:
                self.n -= 1
                self.state = "scan"
                self.feed(t)
        elif self.state == "digit":
            self.state = "scan" if isinstance(t, Operator) else "done"
            if self.state == "scan":
                self.skip = not _heredoc(t)
            else:
                self.found = i - 1
        elif self.state == "scan":
            if isinstance(t, Operator):
                self.skip = not _heredoc(t)
            elif t.isdigit() or isinstance(t, _Fd):
                self.state = "digit"
            elif SUBSTITUTION.match(t) or ASSIGNMENT_WORD.fullmatch(t) or t in WRAPPERS:
                pass
            elif t == "function":
                self.skip = 1  # the function's name
            elif t.rsplit("/", 1)[-1] == "direnv":
                self.state, self.pending = "subcommand", i
            elif (name := t.rsplit("/", 1)[-1]) in OPTION_WRAPPERS:
                self.state, self.wrapper, self.user, self.exec = "options", name, False, False
                self.wrappers.append(name)
            else:
                self.state, self.found = "done", i


def _command_word(tokens):
    """Index of the command a segment runs, after redirections, VAR=value words, wrappers such as sudo and
    timeout with their options, and shell keywords."""
    return Position.of(tokens).found


def runners(spans):
    """For each command of segments(spans=), the index of the command that runs it: the first command with the same
    span, because a `bash -c` script, an `eval`, or an ssh remote command gets the span of the command that runs it.
    A command the string itself runs is its own runner."""
    first = {}
    return [first.setdefault(span, k) for k, span in enumerate(spans)]


def ssh_parts(tokens, words):
    """(options, destination, remote command) of an `ssh` or `tailscale ssh` command, or None for another command.
    options holds the words before and after the destination, as OpenSSH reads both; destination is the word as
    written, `user@` and `ssh://` included, or None when the command has none. words holds the command's words as
    segments(full=) gives them."""
    at = _command_word(tokens)
    if at >= len(tokens) or words[at] is None or _remote(tokens, words, at) is None:
        return None
    args = _args(tokens, words, at + 1)
    if tokens[at].rsplit("/", 1)[-1] == "tailscale":
        args = args[args.index("ssh") + 1:] if "ssh" in args else []
    k = _ssh_options(args, 0)
    if k >= len(args):
        return args, None, []
    end = _ssh_options(args, k + 1)
    return args[:k] + args[k + 1:end], args[k], args[end:]


class Operator(str):
    """A redirection operator in a command's tokens, such as `>`, `2>&`, or `<<`, told apart from a quoted word."""


class _UnreadHeredoc(Operator):
    """`<<` before a delimiter word the scan does not read, such as `$'EOF'`: the word stays in the tokens as its
    target, and the lines after it are read as commands."""


def top_level(command, spans=None):
    """(words, piped) for each command the string itself runs, in one linear read: commands inside
    `$(...)`, backticks, and `bash -c` scripts are not included. Words are uncut. An operator is an Operator,
    with the file descriptor written right before it, as in `2>`. piped is True when the command's output
    goes into a `|` pipe, or may, because it ends a `( ... )` group. A list passed as spans gets the (start, end)
    offsets of each command."""
    spans = [] if spans is None else spans
    t = _Text(command, spans, [0], top=True)
    _scan(t, 0, 0, False)
    return [(tokens, PIPE_AFTER.match(command, last) is not None) for tokens, (_, last) in zip(t.out, spans)]


def pipe_fed(command):
    """The spans, as top_level gives them, of the commands the string itself runs whose standard output goes into a
    `|` pipe, directly or through the groups around them, as in `{ a; b; } | tail` or `for ...; done | tail`. A
    redirection of the standard output of the command, or of a group around it, keeps that output out of the pipe.
    A command longer than NESTED_LIMIT is read as top_level reads it, so each command right before a `|` or a `)`
    counts."""
    if len(command) > NESTED_LIMIT:
        spans = []
        return {span for (_, piped), span in zip(top_level(command, spans), spans) if piped}
    t = _Text(command, None, [NESTED_SHARE * len(command) + NESTED_EXTRA])
    t.pipe_reach = ({}, [])
    _scan(t, 0, 0, False)
    commands, stack = t.pipe_reach
    reached = set()
    while stack:
        feed = stack.pop()
        if id(feed) not in reached:
            reached.add(id(feed))
            stack.extend(item for item in feed if isinstance(item, _Feed))
    return {span for span, feed in commands.items() if id(feed) in reached}
