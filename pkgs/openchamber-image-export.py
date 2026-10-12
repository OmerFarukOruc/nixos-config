# usage: openchamber-image-export.py WEB_DIST_ASSETS_DIR
# A chat message's "save as image" action downloads the rendered PNG through
# an <a download> whose href is the image's data: URL. Electron titles the save
# dialog with the download URL, so the dialog's title is megabytes of base64
# and the GTK file chooser lays out too wide to show its name field or Save
# button. This hands the anchor a blob: URL instead, as the UI's other
# downloads already do.
import pathlib
import re
import sys

pattern = re.compile(
    rb"([\w$]+)\.download=([\w$]+),\1\.href=([\w$]+),"
    rb"document\.body\.appendChild\(\1\),\1\.click\(\),document\.body\.removeChild\(\1\)"
)

replacement = (
    rb"\1.download=\2,\1.href=URL.createObjectURL(await(await fetch(\3)).blob()),"
    rb"document.body.appendChild(\1),\1.click(),document.body.removeChild(\1),"
    rb"URL.revokeObjectURL(\1.href)"
)

count = 0
for path in pathlib.Path(sys.argv[1]).glob("*.js"):
    data = path.read_bytes()
    if b"chat.messageBody.toast.imageSaved" not in data:
        continue
    data, n = pattern.subn(replacement, data)
    if n:
        path.write_bytes(data)
        count += n
if count != 1:
    sys.exit(
        f"openchamber-image-export.py no longer applies: expected 1 data: URL image download "
        f"in {sys.argv[1]}, found {count}. Update the patch, or delete it if the new release "
        "downloads the image through a blob: URL."
    )
print("the message image download now uses a blob: URL")
