import json
import os
import subprocess
import sys

import tomlkit

path, settings_path, herdr = sys.argv[1:]
with open(settings_path) as f:
    settings = json.load(f)
try:
    with open(path) as f:
        text = f.read()
except FileNotFoundError:
    text = ""
doc = tomlkit.parse(text)


def merge(table, values):
    for key, value in values.items():
        if isinstance(value, dict):
            if key not in table:
                table[key] = tomlkit.table()
            merge(table[key], value)
        elif table.get(key) != value:
            table[key] = value


merge(doc, settings)
new = tomlkit.dumps(doc)
if new != text:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        f.write(new)
    os.replace(path + ".tmp", path)
    # Fails harmlessly when no server runs; a new server reads the file.
    subprocess.run([herdr, "server", "reload-config"], capture_output=True)
