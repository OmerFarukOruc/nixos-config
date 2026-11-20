"""The layer graph of a container engine, and each image's part of the bytes that removing images frees."""

import dataclasses
from collections.abc import Iterable

from rows import Row


@dataclasses.dataclass(frozen=True)
class LayerIndex:
    """parent maps each layer to the layer below it; tops maps each image to the layers its chain ends in.

    size is None for a layer whose size the engine does not know. metadata
    holds each image's own bytes outside its layers, such as its manifest
    and config.
    """
    parent: dict[str, str | None]
    size: dict[str, int | None]
    tops: dict[str, tuple[str, ...]]
    metadata: dict[str, int]


def ancestors(index: LayerIndex, layers: Iterable[str]) -> set[str]:
    """The layers and every layer below them."""
    seen, todo = set(), list(layers)
    while todo:
        layer = todo.pop()
        if layer not in seen:
            seen.add(layer)
            if below := index.parent[layer]:
                todo.append(below)
    return seen


def shares(index: LayerIndex, image_ids: Iterable[str]) -> dict[str, int]:
    """Split the bytes that removing all these images frees among them, so the parts add up to that total.

    A layer is freed when no other image and no container builds on it; each
    of these images whose chain holds it gets an equal part. Each image also
    gets its own metadata bytes. Raise ValueError when a freed layer's size
    is unknown.
    """
    ids = sorted(set(image_ids))
    chains = {i: ancestors(index, index.tops[i]) for i in ids}
    theirs = set().union(*chains.values())
    others = [t for i, tops in index.tops.items() if i not in chains for t in tops]
    kept = ancestors(index, [*others, *(layer for layer in index.parent if layer not in theirs)])
    part = {i: index.metadata[i] for i in ids}
    for layer in theirs - kept:
        if (b := index.size[layer]) is None:
            raise ValueError(f"layer `{layer[:12]}` has no recorded size")
        holders = [i for i in ids if layer in chains[i]]
        whole, extra = divmod(b, len(holders))
        for n, i in enumerate(holders):
            part[i] += whole + (n < extra)
    return part


def group_rows(parts: dict[str, int], groups: Iterable[tuple[str, str, dict[str, str], str]]) -> list[Row]:
    """One delete row for each (group, how, entries, reason) with entries; entries map a reference to its image id."""
    rows = []
    for group, how, entries, reason in groups:
        if entries:
            members = {ref: parts[image_id] for ref, image_id in entries.items()}
            b = sum(members.values())
            rows.append(Row(group, "delete", reason, how=how, members=members, alloc=b, frees=b))
    return rows
