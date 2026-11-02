"""Checks the text contrast of every scheme in the theme pack.

usage: python3 -I theme-contrast.py PACK SYSTEM_PACK

PACK is the user's theme pack and SYSTEM_PACK the pack oruc-theme-root reads.
It prints the failures and exits 1 when a text colour stays under 4.5:1.
"""

import json
import re
import sys
from pathlib import Path

pack = Path(sys.argv[1])
system_pack = Path(sys.argv[2])
color = re.compile(r'^\s*"([^"]+)": "#([0-9a-fA-F]+)"', re.M)


def luminance(hex6):
    def linear(channel):
        v = int(channel, 16) / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (linear(hex6[i : i + 2]) for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def words(text):
    return set(text.split())


accent = words(
    """activityBarBadge.foreground button.foreground button.secondaryForeground
    debugView.stateLabelForeground extensionBadge.remoteForeground
    extensionButton.prominentForeground inputValidation.errorForeground
    inputValidation.infoForeground inputValidation.warningForeground
    notification.buttonForeground notification.errorForeground
    notification.infoForeground notification.warningForeground
    statusBar.debuggingForeground statusBar.foreground
    statusBar.noFolderForeground statusBarItem.errorForeground
    statusBarItem.prominentForeground statusBarItem.remoteForeground
    statusBarItem.warningForeground"""
)
hovers = {
    "button.hoverBackground": "button.foreground",
    "button.secondaryHoverBackground": "button.secondaryForeground",
    "extensionButton.prominentHoverBackground": "extensionButton.prominentForeground",
    "notification.buttonHoverBackground": "notification.buttonForeground",
    "statusBarItem.hoverBackground": "statusBar.foreground",
    "statusBarItem.prominentHoverBackground": "statusBarItem.prominentForeground",
}
faint = words(
    """descriptionForeground input.placeholderForeground
    activityBar.inactiveForeground tab.inactiveForeground
    tab.unfocusedInactiveForeground editorLineNumber.foreground
    editorCodeLens.foreground peekViewResult.lineForeground
    peekViewTitleDescription.foreground panelTitle.inactiveForeground
    titleBar.inactiveForeground pickerGroup.foreground
    gitDecoration.ignoredResourceForeground
    debugIcon.breakpointUnverifiedForeground"""
)
dim = words(
    """disabledForeground icon.foreground tab.unfocusedActiveForeground
    editorLineNumber.activeForeground debugIcon.breakpointDisabledForeground"""
)
tokens = {
    "Comment": "faint",
    "Markdown - Line Break": "faint",
    "Operator, Misc": "foreground",
    "Markdown - Plain": "foreground",
}
surfaces = ("editor.background", "sideBar.background")


def background(key):
    return re.sub(r"([fF])oreground$", lambda m: "Background" if m[1] == "F" else "background", key)


def token(text, name):
    found = re.search(rf'"name": "{re.escape(name)}",.*?"foreground": "#([0-9a-fA-F]+)"', text, re.S)
    return found[1] if found else ""


failures = []
checked = skipped = 0
for slug in (pack / "slugs").read_text().split():
    facts = pack / slug / ".oruc"
    theme_file = pack / slug / ".config/oruc/vscode-theme.json"
    names = ("vscode-pairs", "vscode-text", "vscode-label")
    if not theme_file.exists() or not all((facts / name).exists() for name in names):
        failures.append(f"{slug}: the pack has no VS Code theme or its facts")
        continue
    if not (facts / "vscode-label").read_text().startswith("Oruc Base16 "):
        skipped += 1
        continue
    checked += 1
    pairs = {tuple(line.split()) for line in (facts / "vscode-pairs").read_text().splitlines()}
    if pairs != {(fg, background(fg)) for fg in accent}:
        failures.append(f"{slug}: the accent pairs differ from the {len(accent)} expected")
    roles = dict(line.split() for line in (facts / "vscode-text").read_text().splitlines())
    if {k for k, r in roles.items() if r == "faint"} != faint or {k for k, r in roles.items() if r == "dim"} != dim:
        failures.append(f"{slug}: the faint or dim keys differ from the expected lists")
    if roles.get("editor.foreground") != "foreground":
        failures.append(f"{slug}: editor.foreground is not lifted as text")
    text = theme_file.read_text()
    values = dict(color.findall(text))
    for name, role in tokens.items():
        values[name] = token(text, name)
        roles[name] = role
    shared = [
        bg
        for bg in surfaces
        if bg == surfaces[0]
        or any(all(contrast(x, values.get(s, x)) >= 4.5 for s in surfaces) for x in ("000000", "ffffff"))
    ]
    checks = sorted(pairs) + [(fg, hover) for hover, fg in hovers.items()]
    checks += [(key, bg) for key in sorted(roles) for bg in shared]
    for fg, bg in checks:
        if len(values.get(fg, "")) != 6 or len(values.get(bg, "")) != 6:
            failures.append(f"{slug}: {fg} or {bg} is not a six-digit colour")
            continue
        ratio = contrast(values[fg], values[bg])
        if ratio < 4.5:
            failures.append(f"{slug}: {fg} #{values[fg]} on {bg} #{values[bg]} is {ratio:.2f}:1")
    editor = values["editor.background"]
    level = {r: [contrast(values[k], editor) for k in roles if roles[k] == r] for r in ("faint", "dim", "foreground")}
    if max(level["faint"]) > min(level["dim"]) + 0.05 or max(level["dim"]) > min(level["foreground"]) + 0.05:
        failures.append(f"{slug}: faint, dim and normal text are out of order on the editor")
    inactive, active = values["editorLineNumber.foreground"], values["editorLineNumber.activeForeground"]
    if active == inactive and inactive != values["editor.foreground"]:
        failures.append(f"{slug}: the active line number looks like the others")
text_segments = {
    "dir": "base02", "git": "base09", "model": "base0D", "account": "base0C", "clock": "base0E", "cost": "base0F",
}
bar_segments = {"ctx": "base01", "five_hour": "base02", "seven_day": "base01"}
levels = ("low", "mid", "high")


def hex_of(rgb):
    return "".join(f"{int(part):02x}" for part in rgb.split(";"))


def statusline_failures(slug):
    fact = pack / slug / ".oruc/statusline"
    if not fact.exists():
        return [f"{slug}: the pack has no status line fact"]
    data = json.loads(fact.read_text())
    yaml = (pack / slug / ".oruc/source.yaml").read_text()
    found = []
    for name, slot in {**text_segments, **bar_segments}.items():
        segment = data.get("segments", {}).get(name, {})
        scheme = re.search(rf'^\s+{slot}:\s*"#([0-9a-fA-F]{{6}})"', yaml, re.M)
        if "bg" not in segment:
            found.append(f"{slug}: the {name} segment has no bg")
            continue
        bg = hex_of(segment["bg"])
        if not scheme or bg != scheme[1].lower():
            found.append(f"{slug}: the {name} segment is not the scheme's {slot}")
        if name in text_segments:
            drawn = {"fg": segment.get("fg")}
        else:
            used = data.get("used", {}).get(name, {})
            drawn = {f"used {level}": used.get(level) for level in levels}
        for label, value in drawn.items():
            if value is None:
                found.append(f"{slug}: the {name} segment has no {label}")
                continue
            ratio = contrast(hex_of(value), bg)
            if ratio < 4.5:
                found.append(f"{slug}: the {name} segment's {label} {value} is {ratio:.2f}:1")
    return found


obs_var = re.compile(r"^\s*--([a-z_0-9]+): #([0-9a-fA-F]{6});", re.M)
telegram_var = re.compile(r"^([A-Za-z0-9_]+): #([0-9a-f]{6});", re.M)


def telegram_pairs(colors):
    pairs = [
        ("windowFgActive", "windowBgActive"),
        ("sideBarBadgeFg", "sideBarBadgeBg"),
        ("sideBarBadgeFg", "sideBarBadgeBgMuted"),
        ("searchedTextCurrentMatchFg", "searchedTextCurrentMatchBg"),
    ]
    for key in colors:
        if re.fullmatch(r"historyPeer\dUserpicBg2?", key):
            pairs.append(("windowFgActive", key))
        elif key.startswith("settingsIconBg"):
            pairs.append(("settingsIconFg", key))
        elif re.fullmatch(r"premiumButtonBg\d", key):
            pairs.append(("premiumButtonFg", key))
    return pairs


vesktop_var = re.compile(r"^\s*--([a-z0-9-]+): #([0-9a-f]{6}) !important;", re.M)
vesktop_pairs = [
    ("control-primary-text-default", "control-primary-background-default"),
    ("control-primary-text-hover", "control-primary-background-hover"),
    ("control-primary-text-active", "control-primary-background-active"),
    ("badge-primary-text", "badge-primary-background"),
    ("button-filled-brand-text", "button-filled-brand-background"),
    ("button-filled-brand-text-hover", "button-filled-brand-background-hover"),
    ("white", "brand-260"),
    ("white", "brand-500"),
    ("mention-foreground", "mention-background"),
    ("white", "green-360"),
    ("white", "status-positive"),
    ("status-positive-text", "status-positive-background"),
    ("white", "button-danger-background"),
    ("white", "menu-item-danger-hover-bg"),
    ("white", "menu-item-danger-active-bg"),
]


def weak(slug, app, text, background, fg, bg):
    ratio = contrast(fg, bg)
    return [f"{slug}: {app} {text} #{fg} on {background} #{bg} is {ratio:.2f}:1"] if ratio < 4.5 else []


def app_failures(slug):
    found = []
    polarity = (pack / slug / ".oruc/polarity").read_text().strip()
    obs = pack / slug / f".config/obs-studio/themes/Oruc{polarity.title()}.ovt"
    if obs.exists():
        colors = dict(obs_var.findall(obs.read_text()))
        for name in ("primary", "primary_light", "primary_dark"):
            found += weak(slug, "OBS", "text", name, colors["text"], colors[name])
    sourcegit = pack / slug / ".config/oruc/sourcegit-theme.json"
    if sourcegit.exists():
        basic = json.loads(sourcegit.read_text())["BasicColors"]
        for text, background in (("BadgeFG", "Badge"), ("Conflict.Foreground", "Conflict")):
            found += weak(slug, "SourceGit", text, background, basic[text][-6:], basic[background][-6:])
    telegram = pack / slug / ".config/oruc/oruc.tdesktop-palette"
    if telegram.exists():
        colors = dict(telegram_var.findall(telegram.read_text()))
        for text, background in telegram_pairs(colors):
            found += weak(slug, "Telegram", text, background, colors[text], colors[background])
    vesktop = pack / slug / ".config/vesktop/themes/oruc.css"
    if vesktop.exists():
        block = vesktop.read_text().rsplit(".visual-refresh {", 1)[1]
        colors = dict(vesktop_var.findall(block))
        for text, background in vesktop_pairs:
            if text not in colors or background not in colors:
                found.append(f"{slug}: Vesktop sets no {text} or {background}")
                continue
            found += weak(slug, "Vesktop", text, background, colors[text], colors[background])
    return found


gtk_var = re.compile(r"^@define-color ([a-z_]+_color) #([0-9a-fA-F]{6});", re.M)
gtk_fills = ("accent", "destructive", "success", "warning", "error")
kde_selection = re.compile(r"^\[Colors:Selection\]\n(.*?)(?=^\[)", re.M | re.S)
kde_key = re.compile(r"^([A-Za-z]+)=(\d+),(\d+),(\d+)$", re.M)
kde_text = ("ForegroundNormal", "ForegroundActive", "ForegroundLink", "ForegroundVisited")
kde_files = (".local/share/oruc/kde/OrucBase16.colors", ".config/kdeglobals")
tmux_style = re.compile(r'^set -g ([a-z-]+) "fg=#([0-9a-fA-F]{6}),bg=#([0-9a-fA-F]{6})', re.M)
noctalia_fills = ("Primary", "Secondary", "Tertiary", "Error")
sddm_pairs = (("LoginButtonTextColor", "LoginButtonBackgroundColor"), ("HighlightTextColor", "HighlightBackgroundColor"))


def desktop_failures(slug):
    found = []
    gtk_file = pack / slug / ".config/gtk-4.0/oruc-colors.css"
    if gtk_file.exists():
        gtk = dict(gtk_var.findall(gtk_file.read_text()))
        for fill in gtk_fills:
            text, background = f"{fill}_fg_color", f"{fill}_bg_color"
            found += weak(slug, "GTK", text, background, gtk[text], gtk[background])
    kde_file = next((pack / slug / name for name in kde_files if (pack / slug / name).exists()), None)
    if kde_file:
        selection = kde_selection.search(kde_file.read_text())
        keys = {key: "".join(f"{int(c):02x}" for c in rgb) for key, *rgb in kde_key.findall(selection[1])}
        for text in kde_text:
            for background in ("BackgroundNormal", "BackgroundAlternate"):
                found += weak(slug, "KDE", f"Selection {text}", background, keys[text], keys[background])
    tmux_file = pack / slug / ".config/tmux/oruc-theme.conf"
    if tmux_file.exists():
        styles = {style: (fg, bg) for style, fg, bg in tmux_style.findall(tmux_file.read_text())}
        found += weak(slug, "tmux", "window-status-current-style fg", "bg", *styles["window-status-current-style"])
    noctalia_file = pack / slug / ".config/noctalia/palettes/oruc-base16.json"
    if noctalia_file.exists():
        noctalia = json.loads(noctalia_file.read_text())["dark"]
        for fill in noctalia_fills:
            found += weak(slug, "Noctalia", f"mOn{fill}", f"m{fill}", noctalia[f"mOn{fill}"][1:], noctalia[f"m{fill}"][1:])
    dms_file = pack / slug / ".config/dms/oruc-theme.json"
    if dms_file.exists():
        dms = json.loads(dms_file.read_text())["dark"]
        found += weak(slug, "DMS", "primaryText", "primary", dms["primaryText"][1:], dms["primary"][1:])
    sddm_file = system_pack / slug / "sddm.conf.user"
    if sddm_file.exists():
        sddm = dict(re.findall(r'^([A-Za-z]+)="#([0-9a-fA-F]{6})"$', sddm_file.read_text(), re.M))
        for text, background in sddm_pairs:
            found += weak(slug, "SDDM", text, background, sddm[text], sddm[background])
    return found

statusline = []
apps = []
desktop = []
slugs = (pack / "slugs").read_text().split()
for slug in slugs:
    statusline += statusline_failures(slug)
    apps += app_failures(slug)
    desktop += desktop_failures(slug)
for line in (failures + statusline + apps + desktop)[:20]:
    print(f"check-theme: {line}", file=sys.stderr)
if failures or statusline or apps or desktop:
    sys.exit(
        f"check-theme: {len(failures)} VS Code, {len(statusline)} status line,"
        f" {len(apps)} OBS, SourceGit, Vesktop or Telegram"
        f" and {len(desktop)} GTK, KDE, tmux, Noctalia, DMS or SDDM contrast failures"
    )
print(
    f"ok contrast: VS Code text in {checked} schemes;"
    f" {skipped} use their own theme and were skipped"
)
print(f"ok contrast: the Claude Code status line in {len(slugs)} schemes")
print(f"ok contrast: OBS, SourceGit, Vesktop and Telegram accent text in {len(slugs)} schemes")
print(f"ok contrast: GTK, KDE, tmux, Noctalia, DMS and login screen accent text in {len(slugs)} schemes")
