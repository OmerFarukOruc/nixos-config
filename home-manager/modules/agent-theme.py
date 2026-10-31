import json
import os
import re
import signal
import sys

from settings_file import merged_toml, read, replace

OPENCODE_SUBCOMMANDS = {
    "acp", "api", "auth", "debug", "mcp", "mini", "models", "pair", "plugin",
    "reload", "run", "serve", "service", "session", "stats", "uninstall",
    "update", "upgrade",
}
OPENCODE_VALUE_FLAGS = {
    "--completions", "--log-level", "--prompt", "--server", "--session", "-s",
}


def processes():
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
            with open(f"/proc/{pid}/stat") as f:
                ppid = int(f.read().rsplit(")", 1)[1].split()[1])
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                raw = f.read().split(b"\0")[:-1]
        except OSError:
            continue
        argv = [arg.decode(errors="replace") for arg in raw]
        yield int(pid), ppid, exe, argv


def app_processes(app):
    table = {pid: row for pid, *row in processes()}
    servers = {
        pid for pid, (_, _, argv) in table.items()
        if argv[1:2] and argv[1] in app["servers"]
    }

    def served(pid):
        while pid in table:
            if pid in servers:
                return True
            pid = table[pid][0]
        return False

    executables = [re.compile(pattern) for pattern in app["executables"]]
    return [
        (pid, argv)
        for pid, (_, exe, argv) in table.items()
        if any(e.fullmatch(exe) for e in executables) and not served(pid)
    ]


def update(app, new):
    if new == read(app["config"]):
        return
    if app_processes(app):
        print(
            f"theme: {app['name']} runs, so its colours change"
            " at the next theme switch after it closes",
            file=sys.stderr,
        )
        return
    replace(app["config"], new)


def codex(app, fact):
    side = "Dark" if fact["polarity"] == "dark" else "Light"
    values = {
        "tui": {"theme": "oruc"},
        "desktop": {
            f"appearance{side}CodeThemeId": fact["codeTheme"],
            f"appearance{side}ChromeTheme": {**fact["chrome"], "fonts": {}},
        },
    }
    update(app, merged_toml(read(app["config"]), values))


def with_json(app, key_path, value):
    text = read(app["config"])
    data = json.loads(text) if text.strip() else {}
    node = data
    for key in key_path[:-1]:
        node = node.setdefault(key, {})
    node[key_path[-1]] = value
    update(app, json.dumps(data, indent=2) + "\n")


def terminal_ui(argv):
    args = iter(argv[1:])
    for arg in args:
        if arg in OPENCODE_VALUE_FLAGS:
            next(args, None)
        elif not arg.startswith("-"):
            return arg not in OPENCODE_SUBCOMMANDS
    return True


def opencode(app):
    with_json(app, ["theme", "name"], "oruc")
    for pid, argv in app_processes(app):
        if terminal_ui(argv):
            try:
                os.kill(pid, signal.SIGUSR2)
            except ProcessLookupError:
                pass


def main():
    settings_path, command = sys.argv[1:]
    with open(settings_path) as f:
        settings = json.load(f)
    app = settings[command]
    if command == "codex":
        facts = os.path.join(settings["current"], ".oruc", "codex")
        with open(facts) as f:
            codex(app, json.load(f))
    elif command == "opencode":
        opencode(app)
    else:
        with_json(app, ["theme"], "oruc")


main()
