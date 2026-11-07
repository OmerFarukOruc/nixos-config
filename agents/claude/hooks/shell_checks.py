"""Checks on shell expansion that goes wrong silently: a `sed -i` whose script starts with a line address taken from a
shell expansion, and an `rm` whose path holds a glob in a name that sessions share.

`n=$(grep -n PATTERN FILE | cut -d: -f1) && sed -i "${n}s/old/new/" FILE` goes on when grep finds nothing, because the
pipeline exits with cut's status, and with `n` empty the script has no address, so sed edits every line of the file.
`"${n:?}s/old/new/"` stops the command when `n` is empty, and it aborts the whole call before sed runs. An address is
the start of a script or of one of its lines. `$name`, `$1`, `${...}`, and `$(...)` count there when text follows them
on the line; `${n:?}`, `${n:-1}`, and `$((...))` never expand to nothing, and a script that is only `"$script"` has no
address to lose. A `$` that bash reads as a plain character is no expansion: sed's last-line address in `'$a\\'` or
`"\\$d"` passes. A script that `bash -c`, `eval`, or `ssh` runs is read the same way, although the shell that runs it
expands such a `$`, so `bash -c 'sed -i "${n}d" f'` is not checked. Only an in-place edit is checked.

Every session shares /tmp, so a pattern such as `/tmp/deploy-nixos-rog.*` also matches the files of other sessions that
used the same name, and /tmp/agents is shared the same way, because each session's scratch folder sits there as
/tmp/agents/<task>-<session8>/. A glob in the first name under /tmp or under /tmp/agents is denied; a glob further
down stays inside one folder and passes. A path is normalised (`/tmp//x*` and `/tmp/./x*` count as `/tmp/x*`) and read
after quote removal. Not checked: a path from a variable, a relative path after `cd /tmp`, and `find -delete`.

Every check fails open: a command that does not parse lets the call through.
"""
import posixpath
import re

from bash_call import commands_of

# Stands for a `$` that bash reads as a plain character, so the parsed words keep that difference.
LITERAL = "\x01"
# Stands for a quote between two parts of one word, as in `"$n"d`, so the parsed word keeps where the name ends.
BOUNDARY = "\x02"
UNGUARDED = re.compile(r"""(?:^|\n)[ \t\x02]*\$(?:
    (?:[A-Za-z_]\w*(?!\w)|\d|\{(?!\#)(?![A-Za-z_]\w*:?(?:\?|[-=][^}]))[^}]*\})[^\n]*[^\s\x02]
  | \((?!\()[^\n]*\)[^)\n]*[^)\s\x02]
)""", re.VERBOSE)
HEREDOC = re.compile(r"<<(-?)[ \t]*([^\s;&|<>()]+)")
SED_REASON = (
    "This `sed -i` script starts with a line address from a shell expansion. When it expands to nothing, for example "
    "after a `grep -n` that found nothing, sed edits every line of the file. Write the address as "
    '`"${n:?}s/old/new/"`, which stops the command when `n` is empty.'
)


def _word_char(command, k):
    return 0 <= k < len(command) and (command[k].isalnum() or command[k] == "_")


def _literal_dollars(command):
    """command with each `$` that bash reads as a plain character replaced by LITERAL: one in single quotes or in
    `$'...'`, and one after a backslash, which goes with it. A quote between two parts of one word gets a BOUNDARY
    beside it. A `#` comment and an unquoted here-doc body are copied unchanged, because a quote in them is text; a body
    under a quoted delimiter is read as the script a shell may run."""
    out, i, n = [], 0, len(command)
    # "code" for the top level, `$(...)`, and backticks; "dq" inside double quotes; "arith" inside `((...))`
    frames = [["code", 0]]
    pending = []  # here-docs whose bodies start after the current line: (delimiter, strip leading tabs, quoted)
    while i < n:
        c, frame = command[i], frames[-1]
        if c == "\\":
            out.append(LITERAL if command.startswith("$", i + 1) else command[i:i + 2])
            i += 2
            continue
        if command.startswith("$((", i) or (
            frame[0] == "code" and command.startswith("((", i) and (i == 0 or command[i - 1] in " \t\n;&|(")
        ):
            width = 3 if c == "$" else 2
            frames.append(["arith", 0])
            out.append(command[i:i + width])
            i += width
            continue
        if command.startswith("$(", i):
            frames.append(["sub", 0])
            out.append("$(")
            i += 2
            continue
        if frame[0] == "arith":
            if c == ")" and not frame[1] and command.startswith("))", i):
                frames.pop()
                out.append("))")
                i += 2
                continue
            frame[1] = max(frame[1] + (c == "(") - (c == ")"), 0)
            out.append(c)
            i += 1
            continue
        if frame[0] == "dq":
            out.append(c)
            i += 1
            if c == '"':
                frames.pop()
                if _word_char(command, i) or command[i:i + 1] in ("'", '"'):
                    out.append(BOUNDARY)
            elif c == "`":
                frames.append(["bq", 0])
            continue
        if c == "'" or command.startswith("$'", i):
            if _word_char(command, i - 1):
                out.append(BOUNDARY)
            start = i + (c == "$") + 1
            end = start
            while end < n and command[end] != "'":
                end += 2 if c == "$" and command[end] == "\\" else 1
            out.append(command[i:start] + command[start:end + 1].replace("$", LITERAL))
            i = end + 1
            if _word_char(command, i) or command[i:i + 1] in ("'", '"'):
                out.append(BOUNDARY)
            continue
        if c == '"':
            if _word_char(command, i - 1):
                out.append(BOUNDARY)
            frames.append(["dq", 0])
        elif c == "`":
            if frame[0] == "bq":
                frames.pop()
            else:
                frames.append(["bq", 0])
        elif c == "(":
            frame[1] += 1
        elif c == ")":
            if frame[0] == "sub" and not frame[1]:
                frames.pop()
            else:
                frame[1] = max(frame[1] - 1, 0)
        elif c == "#" and (i == 0 or command[i - 1] in " \t\n;&|()"):
            end = command.find("\n", i)
            end = n if end < 0 else end
            out.append(command[i:end])
            i = end
            continue
        elif command.startswith("<<<", i):
            out.append("<<<")
            i += 3
            continue
        elif command.startswith("<<", i):
            if match := HEREDOC.match(command, i):
                word = match[2]
                pending.append((re.sub(r"['\"\\]", "", word), bool(match[1]), any(q in word for q in "'\"\\")))
                out.append(match[0])
                i = match.end()
                continue
        elif c == "\n" and pending:
            i += 1
            out.append(c)
            for delimiter, strip, quoted in pending:
                start = i
                while i < n:
                    end = command.find("\n", i)
                    end = n if end < 0 else end + 1
                    line = command[i:end]
                    if (line.lstrip("\t") if strip else line).rstrip("\n") == delimiter:
                        break
                    i = end
                body = command[start:i]
                out.append(_literal_dollars(body) if quoted else body)
                end = command.find("\n", i)
                end = n if end < 0 else end + 1
                out.append(command[i:end])
                i = end
            pending = []
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _scripts(args):
    """sed's scripts in its argument words, and whether it edits in place; None when a script comes from a file."""
    found, in_place, k, positional = [], False, 0, []
    while k < len(args):
        arg, k = args[k], k + 1
        if arg == "--":
            positional += args[k:]
            break
        if arg.startswith("--"):
            name, equals, value = arg.partition("=")
            if name == "--in-place":
                in_place = True
            elif name == "--expression":
                if not equals:
                    value, k = (args[k] if k < len(args) else ""), k + 1
                found.append(value)
            elif name == "--file":
                return None
            elif name == "--line-length" and not equals:
                k += 1
        elif arg.startswith("-") and len(arg) > 1:
            for j, letter in enumerate(arg[1:], 2):
                if letter == "i":
                    in_place = True
                    break  # the rest of the word is the backup suffix
                if letter in "efl":
                    value = arg[j:]
                    if not value:
                        value, k = (args[k] if k < len(args) else ""), k + 1
                    if letter == "e":
                        found.append(value)
                    elif letter == "f":
                        return None
                    break
        else:
            positional.append(arg)
    if not found and positional:
        found.append(positional[0])
    return found, in_place


GLOB = set("*?[")
SHARED = ("/tmp/agents/", "/tmp/")
RM_REASON = (
    "This `rm` deletes `{}`, a pattern for names that every session shares, so it can match another session's files. "
    "List the matches with `ls` and delete each of your own files by its literal path, or keep scratch files under "
    "/tmp/agents/<task>-<session8>/ and remove that folder by its literal path."
)


def _shared_name_glob(word):
    path = posixpath.normpath(word)
    for root in SHARED:
        if path.startswith(root):
            return bool(GLOB & set(path[len(root):].split("/", 1)[0]))
    return False


def _sed_address_reason(call):
    command = call.command
    if "sed" not in command or "$" not in command:
        return None
    try:
        marked = _literal_dollars(command)
    except RecursionError:  # here-docs nested deeper than Python's stack
        return None
    for sed in commands_of(marked):
        if sed.program != "sed":
            continue
        parsed = _scripts(sed.args_full)
        if parsed and parsed[1] and any(UNGUARDED.search(script) for script in parsed[0]):
            return SED_REASON
    return None


def _tmp_glob_rm_reason(call):
    for rm in call.commands:
        if rm.program != "rm":
            continue
        for word in rm.args_full:
            if _shared_name_glob(word):
                return RM_REASON.format(word)
    return None


CHECKS = (_sed_address_reason, _tmp_glob_rm_reason)
