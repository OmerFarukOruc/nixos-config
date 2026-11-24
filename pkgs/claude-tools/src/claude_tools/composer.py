from __future__ import annotations

import re
from itertools import pairwise
from typing import NamedTuple


class Composer(NamedTuple):
    rows: list[str]
    width: int


def prompt_rows(lines: list[str], marker: str) -> list[str] | None:
    if not lines or not lines[0].startswith(marker):
        return None
    padding = " " * len(marker)
    if any(line and not line.startswith(padding) for line in lines[1:]):
        return None
    return [line[len(marker):] for line in lines]


def claude_box(screen: str, _columns: int) -> Composer | None:
    lines = screen.splitlines()
    rules = [i for i, line in enumerate(lines) if line and not line.strip("─")]
    if len(rules) < 2:
        return None
    start, end = rules[-2:]
    rows = prompt_rows(lines[start + 1:end], "❯\xa0")
    return Composer(rows, len(lines[end]) - 3) if rows else None


def codex_box(screen: str, columns: int) -> Composer | None:
    body, gap, footer = screen.rstrip().rpartition("\n\n")
    if not gap or not all(
        re.fullmatch(r"  (?:← for agents · \? for shortcuts.*|\S[^\n]* · (?:~|/)[^\n]* · .+)", line)
        for line in footer.splitlines()
    ):
        return None
    _, marker, draft = body.rpartition("\n\n› ")
    if not marker:
        return None
    rows = prompt_rows(("› " + draft).split("\n"), "› ")
    return Composer(rows, columns - 2) if rows else None


class OpencodeFrame(NamedTuple):
    box: list[str]
    margin: str
    rule: str


def opencode_frame(screen: str) -> OpencodeFrame | None:
    frame = re.split(r"^( *╹▀+) *$", screen, flags=re.MULTILINE)
    if len(frame) < 3 or "┃" in frame[-1]:
        return None
    box = frame[-3].rsplit("\n\n", 1)[-1].splitlines()
    if len(box) < 4 or box[0].lstrip() != "┃" or box[-2] != box[0]:
        return None
    footer = re.fullmatch(re.escape(box[0]) + r"( {1,2})\S.*", box[-1])
    if not footer:
        return None
    if "ctrl+p commands" not in frame[-1] and not (footer[1] == " " and re.match(r"\n +[~/…]", frame[-1])):
        return None
    return OpencodeFrame(box, box[0] + footer[1], frame[-2])


def opencode_footer_agent(screen: str) -> str | None:
    found = opencode_frame(screen)
    return found.box[-1][len(found.margin):].partition(" · ")[0].strip() if found else None


def opencode_box(screen: str, _columns: int) -> Composer | None:
    found = opencode_frame(screen)
    if not found:
        return None
    box, margin = found.box, found.margin
    rows = box[1:-2]
    if len(rows) >= max(6, len(screen.splitlines()) // 3):
        return None
    if any(line != box[0] and not line.startswith(margin) for line in rows):
        return None
    if any(re.search(r"\[Pasted ~\d+ lines\]", row) for row in rows):
        return None
    width = len(found.rule) - len(margin) - (len(margin) - len(box[0]))
    return Composer([line[len(margin):] for line in rows], width)


BOX_READERS = {"claude": claude_box, "codex": codex_box, "opencode": opencode_box}


def composer_holds(kind: str, screen: str, text: str, columns: int = 0) -> bool:
    reader = BOX_READERS.get(kind)
    box = reader(screen, columns) if reader else None
    if not box or not text.strip():
        return False
    rows = box.rows[:]
    while len(rows) > 1 and rows[-1] == "":
        rows.pop()
    parts = [rows[0]]
    for row, following in pairwise(rows):
        word = following.partition(" ")[0]
        if box.width <= 0 or not (row.isascii() and word.isascii()):
            return False
        if len(row) == box.width and len(row.rpartition(" ")[2]) + len(word) > box.width:
            separator = ""
        elif row and word and len(row) + 1 + len(word) > box.width:
            separator = " "
        else:
            separator = "\n"
        parts.extend((separator, following))
    return "".join(parts) == text
