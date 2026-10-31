import json
import subprocess
import sys

from settings_file import merged_toml, read, replace

path, settings_path, herdr = sys.argv[1:]
with open(settings_path) as f:
    settings = json.load(f)
text = read(path)
new = merged_toml(text, settings)
if new != text:
    replace(path, new)
    subprocess.run([herdr, "server", "reload-config"], capture_output=True)
