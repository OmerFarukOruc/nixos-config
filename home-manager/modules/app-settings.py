import configparser
import io
import json
import os
import re
import signal
import sys

import tomlkit
from settings_file import merge, read, replace

PREF = re.compile(r'^\s*user_pref\("([^"]+)",')


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
    for key, value in values.items():
        if isinstance(value, dict) and isinstance(data.get(key), dict):
            merge_json(data[key], value)
        elif isinstance(value, list) and isinstance(data.get(key), list):
            merge_list(data[key], value)
        else:
            data[key] = value
    return data


def ini_text(text, values):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(text)
    for section, pairs in values.items():
        if not parser.has_section(section):
            parser.add_section(section)
        for key, value in pairs.items():
            parser[section][key] = str(value)
    out = io.StringIO()
    parser.write(out, space_around_delimiters=False)
    return out.getvalue()


def userjs_text(text, values):
    lines = text.splitlines()
    for key, value in values.items():
        line = f"user_pref({json.dumps(key)}, {json.dumps(value)});"
        found = [
            i for i, old in enumerate(lines)
            if PREF.match(old) and PREF.match(old)[1] == key
        ]
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
        doc = tomlkit.parse(text)
        merge(doc, values)
        return tomlkit.dumps(doc)
    if entry["format"] == "ini":
        return ini_text(text, values)
    if entry["format"] == "userjs":
        return userjs_text(text, values)
    raise SystemExit(f"oruc-app-settings: unknown format {entry['format']}")


def changes(app, current):
    for entry in app["files"]:
        for path in paths(app, entry):
            if not entry["create"] and not os.path.exists(path):
                continue
            text = read(path)
            new = rendered(entry, text, current)
            if new != text:
                yield entry, path, new


def terminal_ui(app, argv):
    args = iter(argv[1:])
    for arg in args:
        if arg in app["terminalSignal"]["valueFlags"]:
            next(args, None)
        elif not arg.startswith("-"):
            return arg not in app["terminalSignal"]["subcommands"]
    return True


def apply(app, current):
    pending = list(changes(app, current))
    runs = any(not entry["live"] for entry, _, _ in pending) and bool(
        app_processes(app)
    )
    for entry, path, new in pending:
        if runs and not entry["live"]:
            continue
        replace(path, new)
    if runs:
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


def check(spec, current):
    failed = False
    for name, app in sorted(spec["apps"].items()):
        stale = list(changes(app, current))
        waiting = [e for e, _, _ in stale if not e["live"]]
        if waiting and len(waiting) == len(stale) and app_processes(app):
            print(f"skip {name}: {app['label']} runs, so its settings wait")
            continue
        for _, path, _ in stale:
            print(f"oruc-app-settings: {path} is not set", file=sys.stderr)
        failed = failed or bool(stale)
        if not stale:
            print(f"ok {name} settings")
    return 1 if failed else 0


def main():
    spec_path, command = sys.argv[1:]
    with open(spec_path) as f:
        spec = json.load(f)
    current = spec["current"]
    if command == "--check":
        sys.exit(check(spec, current))
    apply(spec["apps"][command], current)


main()
