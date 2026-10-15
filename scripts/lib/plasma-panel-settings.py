"""Compares the Plasma panel file with the panel settings in the Nix file.

usage: python3 -I plasma-panel-settings.py EXPECTED.json APPLETSRC

EXPECTED.json is /etc/oruc/verify-plasma-panels.json: a list of panels, each
{"location": ..., "widgets": [{"name": ..., "config": {GROUP: {KEY: VALUE}} or null}]}.
APPLETSRC is ~/.config/plasma-org.kde.plasma.desktop-appletsrc. Prints one line
per setting that differs and per widget that the Nix file does not declare,
and exits 1, or prints nothing and exits 0. Exits 2 when a file cannot be read
or compared.

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


def differences(want, got, path=""):
    """Yields each place where got does not hold want, as (path, detail).
    Numbers match by value and a JSON object as a subset. A list of plain
    values, or a comma-separated string that is not a JSON object, reports
    each value it lacks and each value it holds beyond want, and, when both
    hold the same values, a change of order or count. Any other list matches
    item by item."""
    if isinstance(want, str) and want.startswith("{") and isinstance(got, str):
        try:
            want, got = json.loads(want), json.loads(got)
        except ValueError:
            pass
    if isinstance(want, dict):
        if not isinstance(got, dict):
            yield path, mismatch(want, got)
            return
        for key, value in want.items():
            yield from differences(value, got.get(key), f"{path}.{key}" if path else key)
        return
    if isinstance(want, list) or (
        isinstance(want, str) and "," in want and not want.startswith("{") and isinstance(got, str)
    ):
        wants = want if isinstance(want, list) else want.split(",")
        items = got if isinstance(got, list) else (got.split(",") if isinstance(got, str) and got else [])
        if all(not isinstance(value, (dict, list)) for value in wants):
            yield from list_differences(wants, items, path)
            return
        for index, value in enumerate(wants):
            got_item = items[index] if index < len(items) else None
            yield from differences(value, got_item, f"{path}[{index}]")
        for index in range(len(wants), len(items)):
            yield f"{path}[{index}]", mismatch(None, items[index])
        return
    if isinstance(want, (int, float)) and not isinstance(want, bool):
        try:
            if not isinstance(got, bool) and abs(float(got) - float(want)) < 1e-9:
                return
        except (TypeError, ValueError):
            pass
        yield path, mismatch(want, got)
        return
    if got is None or text(want) != text(got):
        yield path, mismatch(want, got)


def value_key(value):
    """Numbers match by value, as in differences."""
    if not isinstance(value, bool):
        try:
            return float(value)
        except (TypeError, ValueError):
            pass
    return text(value)


def list_differences(wants, items, path):
    want_keys = [value_key(value) for value in wants]
    got_keys = [value_key(value) for value in items]
    # A list item is shown whole, because a cut name hides which item it is.
    for value, key in zip(wants, want_keys):
        if key not in got_keys:
            yield path, f"lacks {text(value)}"
    for value, key in zip(items, got_keys):
        if key not in want_keys:
            yield path, f"also holds {text(value)}"
    if set(want_keys) == set(got_keys) and want_keys != got_keys:
        yield path, f"holds another order or count: {mismatch(wants, items)}"


def mismatch(want, got):
    return f"want {short(want)}, got {short(got)}"


def short(value):
    shown = "nothing" if value is None else text(value)
    return shown if len(shown) <= 60 else shown[:57] + "..."


def problem(where, name, key, found):
    path, detail = found
    place = f"{key}{'.' if path and not path.startswith('[') else ''}{path}"
    return f"{where} panel: {name} {place}: {detail}"


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
        matched = set()
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
            matched.add(candidates[index])
            base = ("Containments", match, "Applets", candidates[index], "Configuration")
            for group, settings in (widget.get("config") or {}).items():
                stored = groups.get(base + tuple(group.split("/")), {})
                for key, want in settings.items():
                    for found in differences(want, stored.get(key)):
                        problems.append(problem(where, name, key, found))
            profile = active_profile(groups.get(base + ("General",), {}))
            if profile is not None:
                for key, want in ((widget.get("config") or {}).get("General") or {}).items():
                    if key in profile:
                        for found in differences(want, profile[key]):
                            problems.append(problem(where, name, f"profile {key}", found))
        for aid in applets:
            if aid not in matched:
                plugin = groups[("Containments", match, "Applets", aid)].get("plugin")
                problems.append(f"{where} panel: {plugin} is not in plasma-panels.nix")
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
