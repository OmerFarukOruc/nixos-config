import configparser
import functools
import io
import json
import os
import re
import signal
import socket
import sys

import tomlkit
from settings_file import merged_toml, read, replace

PREF = re.compile(r'^\s*user_pref\("([^"]+)",')
BOM = "\ufeff"
BROKEN = (OSError, ValueError, configparser.Error)


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
    commands = [re.compile(pattern) for pattern in app["commandLines"]]

    def ours(exe, argv):
        line = " ".join(argv)
        return any(e.fullmatch(exe) for e in executables) or any(
            c.search(line) for c in commands
        )

    return [
        (pid, argv)
        for pid, (_, exe, argv) in table.items()
        if ours(exe, argv) and not served(pid)
    ]


def vault_folders(app):
    text = read(app["vaults"])
    vaults = json.loads(text).get("vaults", {}) if text.strip() else {}
    return [vault["path"] for vault in vaults.values()]


def default_profile(app):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(read(app["profiles"]))
    base = os.path.dirname(app["profiles"])
    for section in parser.sections():
        if section.startswith("Install") and parser[section].get("Default"):
            return [os.path.join(base, parser[section]["Default"])]
    for section in parser.sections():
        profile = parser[section]
        if section.startswith("Profile") and profile.get("Default") == "1":
            path = profile.get("Path", "")
            relative = profile.get("IsRelative", "1") == "1"
            return [os.path.join(base, path) if relative else path]
    return []


def paths(app, entry):
    path = entry["path"]
    if "{vault}" in path:
        return [path.replace("{vault}", v) for v in vault_folders(app)]
    if "{profile}" in path:
        return [path.replace("{profile}", p) for p in default_profile(app)]
    return [path]


def merge_list(items, values):
    def key(item):
        if isinstance(item, dict) and "identifier" in item:
            return item["identifier"].get("id")
        return json.dumps(item, sort_keys=True)

    keys = [key(item) for item in items]
    for value in values:
        if key(value) not in keys:
            items.append(value)
            keys.append(key(value))
            continue
        index = keys.index(key(value))
        if isinstance(value, dict) and isinstance(items[index], dict):
            merge_json(items[index], value)
        else:
            items[index] = value
    return items


def merge_json(data, values):
    if isinstance(values, list):
        return merge_list(data if isinstance(data, list) else [], values)
    if not isinstance(data, dict):
        raise ValueError(f"holds a JSON {type(data).__name__}, not an object")
    for key, value in values.items():
        if isinstance(value, dict) and isinstance(data.get(key), dict):
            merge_json(data[key], value)
        elif isinstance(value, list) and isinstance(data.get(key), list):
            merge_list(data[key], value)
        else:
            data[key] = value
    return data


def ini_parsed(text):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(text.removeprefix(BOM))
    return parser


def ini_text(text, values):
    parser = ini_parsed(text)
    for section, pairs in values.items():
        if not parser.has_section(section):
            parser.add_section(section)
        for key, value in pairs.items():
            parser[section][key] = str(value)
    out = io.StringIO()
    parser.write(out, space_around_delimiters=False)
    return (BOM if text.startswith(BOM) else "") + out.getvalue()


def userjs_text(text, values):
    lines = text.splitlines()
    for key, value in values.items():
        line = f"user_pref({json.dumps(key)}, {json.dumps(value)});"
        found = [
            i for i, old in enumerate(lines)
            if PREF.match(old) and PREF.match(old)[1] == key
        ]
        lines = [old for i, old in enumerate(lines) if i not in found[1:]]
        if found:
            lines[found[0]] = line
        else:
            lines.append(line)
    return "\n".join(lines) + "\n"


def values_of(entry, current):
    if entry.get("fact"):
        with open(os.path.join(current, ".oruc", entry["fact"])) as f:
            return json.load(f)
    return entry["values"]


def rendered(entry, text, current):
    if entry["format"] == "copy":
        return read(os.path.join(current, entry["source"]))
    values = values_of(entry, current)
    if entry["format"] == "json":
        empty = [] if isinstance(values, list) else {}
        data = json.loads(text) if text.strip() else empty
        return json.dumps(merge_json(data, values), indent=2) + "\n"
    if entry["format"] == "toml":
        return merged_toml(text, values)
    if entry["format"] == "ini":
        return ini_text(text, values)
    return userjs_text(text, values)


def meaning(entry, text):
    if entry["format"] == "json":
        return json.loads(text) if text.strip() else None
    if entry["format"] == "toml":
        return tomlkit.parse(text).unwrap()
    if entry["format"] == "ini":
        parser = ini_parsed(text)
        return {name: dict(parser[name]) for name in parser.sections()}
    return text


def updates(app, entries, current, failures):
    found = []
    for entry in entries:
        try:
            targets = paths(app, entry)
        except BROKEN as error:
            failures.append(f"{entry['path']}: {error}")
            continue
        for path in targets:
            if not entry["create"] and not os.path.exists(path):
                continue
            try:
                text = read(path)
                new = rendered(entry, text, current)
                if meaning(entry, new) != meaning(entry, text):
                    found.append((entry, path, new))
            except BROKEN as error:
                failures.append(f"{path}: {error}")
    return found


def terminal_ui(app, argv):
    args = iter(argv[1:])
    for arg in args:
        if arg in app["terminalSignal"]["valueFlags"]:
            next(args, None)
        elif not arg.startswith("-"):
            subcommands = app["terminalSignal"]["subcommands"]
            return not any(re.fullmatch(s, arg) for s in subcommands)
    return True


def report(failures):
    for failure in failures:
        print(f"oruc-app-settings: {failure}", file=sys.stderr)


def lock_held(lock, pids):
    try:
        target = os.readlink(lock)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    host, _, pid = target.rpartition("-")
    if host != socket.gethostname():
        return True
    return pid.isdigit() and int(pid) in pids()


def waiter(app):
    @functools.cache
    def pids():
        return {pid for pid, _ in app_processes(app)}

    def waits(entry):
        if entry["live"]:
            return False
        if entry["lock"]:
            return lock_held(entry["lock"], pids)
        return bool(pids())

    return waits


def apply(app, current):
    failures = []
    waits = waiter(app)
    live = [entry for entry in app["files"] if entry["live"]]
    later = [entry for entry in app["files"] if not entry["live"]]
    for _, path, new in updates(app, live, current, failures):
        replace(path, new)
    held = False
    for entry, path, new in updates(app, later, current, failures):
        if waits(entry):
            held = True
        else:
            replace(path, new)
    if held:
        print(
            f"theme: {app['label']} runs, so its colours change"
            " at the next theme switch after it closes",
            file=sys.stderr,
        )
    if app.get("terminalSignal"):
        number = signal.Signals[app["terminalSignal"]["name"]]
        for pid, argv in app_processes(app):
            if terminal_ui(app, argv):
                try:
                    os.kill(pid, number)
                except ProcessLookupError:
                    pass
    report(failures)
    return 1 if failures else 0


def check(spec, current):
    failed = False
    for name, app in sorted(spec["apps"].items()):
        failures = []
        waits = waiter(app)
        stale = updates(app, app["files"], current, failures)
        decided = [(path, waits(entry)) for entry, path, _ in stale]
        held = [path for path, wait in decided if wait]
        failures += [
            f"{path} is not set" for path, wait in decided if not wait
        ]
        report(failures)
        failed = failed or bool(failures)
        if held:
            print(f"skip {name}: {app['label']} runs, so its settings wait")
        elif not failures:
            print(f"ok {name} settings")
    return 1 if failed else 0


def main():
    spec_path, command = sys.argv[1:]
    with open(spec_path) as f:
        spec = json.load(f)
    current = spec["current"]
    if command == "--check":
        sys.exit(check(spec, current))
    sys.exit(apply(spec["apps"][command], current))


main()
