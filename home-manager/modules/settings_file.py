import collections.abc
import os

import tomlkit


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""


def replace(path, text):
    try:
        mode = os.stat(path).st_mode & 0o7777
    except FileNotFoundError:
        mode = 0o600
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.oruc-tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def merge(table, values):
    for key, value in values.items():
        if isinstance(value, dict):
            if key not in table:
                table[key] = tomlkit.table()
            elif not isinstance(table[key], collections.abc.Mapping):
                raise ValueError(
                    f"{key} holds a TOML {type(table[key]).__name__}, not a table"
                )
            merge(table[key], value)
        elif table.get(key) != value:
            table[key] = value


def merged_toml(text, values):
    doc = tomlkit.parse(text)
    merge(doc, values)
    return tomlkit.dumps(doc)
