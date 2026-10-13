"""Compares the Plasma panel file with the panel settings in the Nix file.

usage: python3 -I plasma-panel-settings.py EXPECTED.json APPLETSRC

EXPECTED.json is /etc/oruc/verify-plasma-panels.json: a list of panels, each
{"location": ..., "widgets": [{"name": ..., "config": {GROUP: {KEY: VALUE}} or null}]}.
APPLETSRC is ~/.config/plasma-org.kde.plasma.desktop-appletsrc. Prints one line
per setting that differs and exits 1, or prints nothing and exits 0. Exits 2
when a file cannot be read or compared.

A widget that keeps its settings in profiles (kVitals' profileList) reads
only its active profile, so the declared keys found in that profile are
compared there too.
"""

import json
import re
import sys

# Plasma's Types::Location values.
LOCATIONS = {"floating": "0", "top": "3", "bottom": "4", "left": "5", "right": "6"}
UNESCAPES = {"\\": "\\", "n": "\n", "t": "\t", "r": "\r", "s": " "}


def read_kconfig(path):
    """Returns {group path tuple: {key: value}} for a KConfig INI file."""
    groups = {}
    current = None
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            line = line.rstrip("\n")
            if line.startswith("["):
                current = tuple(re.findall(r"\[([^\]]*)\]", line))
                groups.setdefault(current, {})
            elif current is not None and "=" in line:
                key, value = line.split("=", 1)
                key = re.sub(r"\[\$[a-z]+\]$", "", key)
                groups[current][key] = re.sub(
                    r"\\(.)", lambda m: UNESCAPES.get(m.group(1), m.group(0)), value
                )
    return groups


def text(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return ",".join(text(item) for item in value)
    return str(value)


def difference(want, got, path=""):
    """The first place where got does not hold want, as (path, want, got), or
    None. Numbers match by value, a JSON object as a subset, a list in order."""
    if isinstance(want, str) and want.startswith("{") and isinstance(got, str):
        try:
            return difference(json.loads(want), json.loads(got), path)
        except ValueError:
            pass
    if isinstance(want, dict):
        if not isinstance(got, dict):
            return path, want, got
        for key, value in want.items():
            found = difference(value, got.get(key), f"{path}.{key}" if path else key)
            if found:
                return found
        return None
    if isinstance(want, list):
        items = got if isinstance(got, list) else (got.split(",") if got else [])
        for index, value in enumerate(want):
            if index >= len(items):
                return f"{path}[{index}]", value, None
            found = difference(value, items[index], f"{path}[{index}]")
            if found:
                return found
        if len(items) > len(want):
            return f"{path}[{len(want)}]", None, items[len(want)]
        return None
    if isinstance(want, (int, float)) and not isinstance(want, bool):
        try:
            if not isinstance(got, bool) and abs(float(got) - float(want)) < 1e-9:
                return None
        except (TypeError, ValueError):
            pass
        return path, want, got
    return None if got is not None and text(want) == text(got) else (path, want, got)


def short(value):
    shown = "nothing" if value is None else text(value)
    return shown if len(shown) <= 60 else shown[:57] + "..."


def problem(where, name, key, found):
    path, want, got = found
    place = f"{key}{'.' if path and not path.startswith('[') else ''}{path}"
    return f"{where} panel: {name} {place}: want {short(want)}, got {short(got)}"


def applets_in_order(groups, containment):
    ids = [
        path[3]
        for path in groups
        if len(path) == 4 and path[:3] == ("Containments", containment, "Applets")
    ]
    order = groups.get(("Containments", containment, "General"), {}).get("AppletOrder")
    ranked = order.split(";") if order else []
    return sorted(
        ids,
        key=lambda aid: (ranked.index(aid) if aid in ranked else len(ranked), int(aid)),
    )


def active_profile(general):
    try:
        profiles = json.loads(general["profileList"])["profiles"]
    except (KeyError, ValueError, TypeError):
        return None
    for profile in profiles:
        if profile.get("id") == general.get("activeProfileId"):
            return profile.get("data")
    return profiles[0].get("data") if profiles else None


def compare(panels, groups):
    problems = []
    containments = sorted(
        (path[1] for path in groups if len(path) == 2 and path[0] == "Containments"),
        key=int,
    )
    used = set()
    for panel in panels:
        where = panel["location"]
        match = next(
            (
                cid
                for cid in containments
                if cid not in used
                and groups[("Containments", cid)].get("plugin") == "org.kde.panel"
                and groups[("Containments", cid)].get("location")
                == LOCATIONS.get(where)
            ),
            None,
        )
        if match is None:
            problems.append(f"{where} panel: missing")
            continue
        used.add(match)
        applets = applets_in_order(groups, match)
        seen = {}
        for widget in panel["widgets"]:
            name = widget["name"]
            candidates = [
                aid
                for aid in applets
                if groups[("Containments", match, "Applets", aid)].get("plugin") == name
            ]
            index = seen.get(name, 0)
            seen[name] = index + 1
            if index >= len(candidates):
                problems.append(f"{where} panel: {name} missing")
                continue
            base = ("Containments", match, "Applets", candidates[index], "Configuration")
            for group, settings in (widget.get("config") or {}).items():
                stored = groups.get(base + tuple(group.split("/")), {})
                for key, want in settings.items():
                    found = difference(want, stored.get(key))
                    if found:
                        problems.append(problem(where, name, key, found))
            profile = active_profile(groups.get(base + ("General",), {}))
            if profile is not None:
                for key, want in ((widget.get("config") or {}).get("General") or {}).items():
                    found = key in profile and difference(want, profile[key])
                    if found:
                        problems.append(problem(where, name, f"profile {key}", found))
    return problems


def main():
    if len(sys.argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as expected:
            panels = json.load(expected)
        groups = read_kconfig(sys.argv[2])
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2
    try:
        problems = compare(panels, groups)
    except Exception as error:  # A malformed file must not read as a difference.
        print(f"cannot compare: {error!r}", file=sys.stderr)
        return 2
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
