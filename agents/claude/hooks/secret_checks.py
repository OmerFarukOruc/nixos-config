"""Checks that keep secret values out of a call's output, where the agent's transcript and the model's input keep them.

Three `infisical` forms print every value of a folder: `secrets` with no subcommand (a listing), `export` without a file
to write, and `run` around a bare `env` or `printenv`. Each is read the same way under `infisical sm`, the command group that
holds them too. The global and per-command flags that take a value (`infisical help`, `infisical help secrets`, CLI
0.44) are skipped with their value, so a flag value such as `--env get` is never read as a subcommand.

- A listing passes only when its output goes through a pipe straight into a `jq` whose filter reads `secretKey`, never
  names `secretValue`, does not end in a step that prints whole records (`.`, `.[]`, `.[0]`, `select(...)`), and does not
  print the record beside the names (`.secretKey, .`), unless an earlier step keeps the names only. This stops a listing written by mistake; a filter built to print
  values, such as one that ends in `tojson`, passes. `infisical secrets get` prints only the values it names and passes.
- An export passes only with `--output-file` (`-o`) set to a path outside `/dev` and `/proc`, and without `--template`,
  which renders to stdout even when an output file is set. A `>` redirection does not count, because bash_call reads
  `2>` and `>/dev/stdout` as file writes.
- `-h`, `--help`, `-v` and `--version` pass.

A command that `bash -c` runs, or one inside a `{ ...; }` group, is checked without its pipe, so a safe listing there is
refused too. A call that does not parse is let through.
"""
import re

GROUP = "sm"
SUBCOMMANDS = {"agent-proxy", "delete", "folders", "generate-example-env", "get", "set"}
FLAGS_WITHOUT_VALUE = {
    "--expand", "--help", "--include-imports", "--plain", "--recursive", "--secret-overriding", "--silent",
    "--telemetry", "--version", "--watch", "-h", "-v",
}
HELP = {"-h", "--help", "-v", "--version"}
OUTPUT_FILE = {"-o", "--output-file"}
COMMAND = {"-c", "--command"}
DEVICES = ("/dev/", "/proc/")
ENVIRONMENT_DUMPS = {"env", "printenv"}
JQ_OPTIONS_WITH_TWO_VALUES = {"--arg", "--argjson", "--slurpfile", "--rawfile"}
JQ_OPTIONS_WITH_ONE_VALUE = {"--indent", "-L", "--library-path"}
JQ_FILTER_FROM_FILE = {"-f", "--from-file"}
WHOLE_RECORD = re.compile(r"\s*(?:\.|\.\[\d*\]\??|select\(.*\))\s*")
RECORD_BESIDE = re.compile(r",\s*\.\s*(?:$|[,)\]|])")
NAMES_STEP = re.compile(r"\s*\[?\s*(?:\.\[\]\??)?\.secretKey\s*")
LISTING_REASON = (
    "`infisical secrets` without a subcommand prints every value in the folder. List the names only: "
    "`infisical secrets --path <path> -o json --silent | jq -r '.[]?.secretKey'`. Write one value to a 0600 file with "
    "`(umask 077; infisical secrets get <NAME> --path <path> --plain --silent > <file>)`."
)
EXPORT_REASON = (
    "`infisical export` prints every value in the folder unless it writes a file. Write it to a 0600 file: "
    "`(umask 077; infisical export --path <path> --format dotenv --output-file <file>)`, without `--template`."
)
RUN_REASON = (
    "`infisical run` around `env` or `printenv` prints every injected value. Run the program that needs the values: "
    "`infisical run --path <path> -- <program>`."
)


def _flag_value(args, k):
    """The value of the flag at args[k], or None when it takes none or carries it after `=`."""
    arg = args[k]
    if "=" in arg or arg in FLAGS_WITHOUT_VALUE or k + 1 >= len(args):
        return None
    return args[k + 1]


def _read(args):
    """The positional words of an `infisical` command, up to `--`, each flag with its value, and the words after `--`."""
    positional, flags, k = [], {}, 0
    while k < len(args) and args[k] != "--":
        arg = args[k]
        if not arg.startswith("-"):
            positional.append(arg)
            k += 1
            continue
        name, _, inline = arg.partition("=")
        value = inline or _flag_value(args, k)
        flags[name] = value
        k += 1 if inline or value is None else 2
    return positional, flags, args[k + 1:]


def _jq_filter(args):
    """The filter a `jq` call runs, or None when it reads it from a file."""
    k = 0
    while k < len(args):
        arg = args[k]
        if arg in JQ_FILTER_FROM_FILE:
            return None
        if arg in JQ_OPTIONS_WITH_TWO_VALUES:
            k += 3
        elif arg in JQ_OPTIONS_WITH_ONE_VALUE:
            k += 2
        elif arg.startswith("-"):
            k += 1
        else:
            return arg
    return None


def _steps(jq_filter):
    """The filter split at each `|` outside brackets and strings."""
    steps, depth, quoted, start = [], 0, False, 0
    for k, char in enumerate(jq_filter):
        if char == '"' and (k == 0 or jq_filter[k - 1] != "\\"):
            quoted = not quoted
        elif not quoted and char in "([{":
            depth += 1
        elif not quoted and char in ")]}":
            depth -= 1
        elif not quoted and depth == 0 and char == "|":
            steps.append(jq_filter[start:k])
            start = k + 1
    return [*steps, jq_filter[start:]]


def _names_only(commands, k):
    if commands[k].connector_after != "|" or k + 1 >= len(commands) or commands[k + 1].program != "jq":
        return False
    jq_filter = _jq_filter(commands[k + 1].args_full)
    if jq_filter is None or "secretKey" not in jq_filter or "secretValue" in jq_filter:
        return False
    steps = _steps(jq_filter)
    if any(NAMES_STEP.fullmatch(step) for step in steps):
        return True
    return WHOLE_RECORD.fullmatch(steps[-1]) is None and RECORD_BESIDE.search(jq_filter) is None


def _writes_export(flags):
    target = next((flags[name] for name in OUTPUT_FILE if flags.get(name)), None)
    return target is not None and not target.startswith(DEVICES) and "--template" not in flags


def _dumps_environment(flags, program_args):
    """Whether the program `run` starts prints the whole environment: `printenv` with no name, or `env` that sets
    variables and starts no program."""
    command = next((flags[name] for name in COMMAND if flags.get(name)), None)
    words = command.split() if command else program_args
    if not words or words[0].rsplit("/", 1)[-1] not in ENVIRONMENT_DUMPS:
        return False
    return all(word.startswith("-") or "=" in word for word in words[1:])


def _infisical_reason(call):
    commands = call.commands
    for k, command in enumerate(commands):
        if command.program != "infisical":
            continue
        positional, flags, program_args = _read(command.args_full)
        if HELP & flags.keys():
            continue
        if positional[:1] == [GROUP]:
            positional = positional[1:]
        verb, subcommand = (positional + ["", ""])[:2]
        if verb == "secrets" and subcommand not in SUBCOMMANDS and not _names_only(commands, k):
            return LISTING_REASON
        if verb == "export" and not _writes_export(flags):
            return EXPORT_REASON
        if verb == "run" and _dumps_environment(flags, program_args):
            return RUN_REASON
    return None


CHECKS = (_infisical_reason,)
