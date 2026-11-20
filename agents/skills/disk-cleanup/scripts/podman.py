"""Rows for Podman images, volumes, and containers."""

import glob
import json
import os
import shutil
import time
from typing import NamedTuple

from activity import session_mentions
from config import RECENT
from docker import Engine, container_group_rows, created, volume_group_rows
from holders import inside
from layers import LayerIndex, group_rows, shares
from rows import CommandError, Row, run

LOCAL_HOST = "localhost"
REMOTE_VARIABLES = ("CONTAINER_HOST", "CONTAINER_CONNECTION")
STOPPED = ("exited", "stopped")


class Store(NamedTuple):
    root: str
    run_root: str
    driver: str


def podman() -> Engine:
    """Read Podman's graph root; Podman has no daemon, so the CLI is the endpoint.

    A remote connection or a volume path outside the graph root is not
    measured, because the checks read local files under the graph root.
    """
    def unmeasured(reason: str) -> Engine:
        failure = [Row("Podman", "look", reason)]
        return Engine(None, None, lambda: failure)
    if not shutil.which("podman"):
        return Engine(None, None, list)
    if remote := [v for v in REMOTE_VARIABLES if os.environ.get(v)]:
        return unmeasured(f"`{remote[0]}` points Podman at another engine; not measured")
    try:
        fields = "{{.Store.GraphRoot}} {{.Store.VolumePath}} {{.Store.RunRoot}} {{.Store.GraphDriverName}}"
        root, volumes, run_root, driver = run(["podman", "info", "--format", fields]).split()
    except (CommandError, ValueError) as e:
        return unmeasured(str(e))
    if not inside(volumes, root):
        return unmeasured(f"its volume path `{volumes}` is outside its graph root `{root}`; not measured")
    return Engine(None, root, lambda: podman_rows(Store(root, run_root, driver)))


def podman_rows(store: Store) -> list[Row]:
    return [*image_rows(store), *volume_rows(), *container_rows(), *stopped_container_rows()]


def stored(root: str, image_id: str) -> float | None:
    """When the image reached this host, or None when its folder is not in the graph root.

    Podman's `Created` is the build time, which is 1980 for reproducible
    builds, so the mtime of the image's `<driver>-images/<id>` folder stands in.
    """
    for folder in glob.glob(f"{glob.escape(root)}/*-images/{image_id}"):
        return os.stat(folder).st_mtime
    return None


def names_of(image: dict) -> list[str]:
    return image.get("Names") or [image["Id"][:12]]


def pulled(image: dict) -> bool:
    """An image with a digest from a registry other than this host."""
    return any(not d.startswith(f"{LOCAL_HOST}/") for d in image.get("RepoDigests") or [])


def read_index(path: str, required: bool) -> list[dict]:
    try:
        with open(path) as f:
            records = json.load(f) or []
    except FileNotFoundError:
        if required:
            raise ValueError(f"`{path}` is missing") from None
        return []
    except (OSError, ValueError) as e:
        raise ValueError(f"`{path}`: {e}") from e
    if not isinstance(records, list) or not all(isinstance(r, dict) for r in records):
        raise ValueError(f"`{path}` is not a list of records")
    return records


def known_size(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def layer_index(store: Store) -> LayerIndex:
    """Parse c/storage's index files once; raise ValueError naming the file when one is missing or inconsistent.

    `podman images --format json` prints SharedSize 0 for every image, so its
    sizes count base layers once per image that builds on them; the index
    holds the layer graph instead. c/storage writes `diff-size` -1 for a
    layer of a partial pull, which becomes an unknown size. A transient store
    keeps `volatile-layers.json` under the run root, so both roots are read.
    """
    layers_path = os.path.join(store.root, f"{store.driver}-layers", "layers.json")
    images_path = os.path.join(store.root, f"{store.driver}-images", "images.json")
    volatile = [os.path.join(r, f"{store.driver}-layers", "volatile-layers.json") for r in (store.root, store.run_root)]
    layers = [*read_index(layers_path, True), *(la for path in volatile for la in read_index(path, False))]
    images = read_index(images_path, True)
    try:
        parent = {la["id"]: la.get("parent") or None for la in layers}
        size = {la["id"]: known_size(la.get("diff-size")) for la in layers}
        tops = {i["id"]: tuple(filter(None, (i.get("layer"), *(i.get("mapped-layers") or [])))) for i in images}
        metadata = {i["id"]: sum((i.get("big-data-sizes") or {}).values()) for i in images}
    except (KeyError, TypeError, AttributeError) as e:
        raise ValueError(f"a record in `{layers_path}` or `{images_path}` lacks a field ({e!r})") from e
    named = {p for p in parent.values() if p} | {t for ts in tops.values() for t in ts}
    if missing := named - parent.keys():
        raise ValueError(f"{len(missing)} layers that images or layers name are not in `{layers_path}`")
    return LayerIndex(parent, size, tops, metadata)


def image_rows(store: Store) -> list[Row]:
    """Unused images as two delete groups, and the young or named ones as look rows.

    `podman images` prints one entry per tag, so entries are merged by id. A
    pulled image goes in group:podman-images, and remove.py asks its
    registry first. Every other unused image is a local build or an untagged
    layer, which the build that made it recreates; it goes in
    group:podman-builds unless it is under RECENT old or a running agent
    named one of its names. A delete entry's size is its share of what
    removing both groups frees, so the two rows add up to that; a look row's
    size is its share of what removing every unused image frees.
    """
    unused = {i["Id"]: i for i in json.loads(run(["podman", "images", "--format", "json"])) if not i.get("Containers")}
    named = session_mentions([n for i in unused.values() for n in names_of(i)])
    look, registry, builds = {}, {}, {}
    for image_id, i in unused.items():
        ref, at = names_of(i)[0], stored(store.root, image_id)
        mention = next((named[n] for n in names_of(i) if n in named), None)
        if mention or at is None or time.time() - at < RECENT:
            look[image_id] = (ref, mention or ("not stored here for 24 h yet" if at else "no storage time"))
        else:
            (registry if pulled(i) else builds)[ref] = image_id
    try:
        index = layer_index(store)
        if missing := unused.keys() - index.tops.keys():
            raise ValueError(f"{len(missing)} images that `podman images` lists are not in `images.json`")
        look_parts, parts = shares(index, unused), shares(index, [*registry.values(), *builds.values()])
    except ValueError as e:
        return [Row("Podman images", "look", f"the layer index could not be read ({e}); not measured")]
    return [*(Row(f"Podman image `{ref}`", "look", f"no container uses it; {why}", alloc=look_parts[image_id])
              for image_id, (ref, why) in look.items()),
            *group_rows(parts, [
                ("group:podman-images", "podman-image", registry,
                 "unused pulled images; `podman pull` brings each back"),
                ("group:podman-builds", "podman-build", builds,
                 ("unused local builds and untagged images, stored 24+ h ago; the build that made each makes it "
                  "again, but a source that is gone does not come back"))])]


def dangling_volumes() -> set[str]:
    return set(run(["podman", "volume", "ls", "-q", "-f", "dangling=true"]).split())


def volume_bytes(mountpoint: str) -> int:
    """`podman unshare` reads the files that belong to subordinate uids."""
    try:
        return int(run(["podman", "unshare", "du", "-sxB1", mountpoint]).split()[0])
    except (CommandError, ValueError, IndexError):
        return 0


def volume_rows() -> list[Row]:
    """Old orphaned anonymous volumes on delete, young anonymous and unused named ones on look, used ones on leave.

    An anonymous volume belongs to the container that made it; once that
    container is gone, nothing attaches it again. A named volume holds
    data someone chose to keep, so it never goes on delete.
    """
    names = run(["podman", "volume", "ls", "-q"]).split()
    if not names:
        return []
    dangling = dangling_volumes()
    old, young, named, used = {}, {}, {}, 0
    for v in json.loads(run(["podman", "volume", "inspect", *names])):
        name, b = v["Name"], volume_bytes(v["Mountpoint"])
        if name not in dangling:
            used += b
        elif not v.get("Anonymous"):
            named[name] = b
        else:
            (young if time.time() - created(v) < RECENT else old)[name] = b
    rows = volume_group_rows("podman", old, young)
    if named:
        rows.append(Row("group:podman-volumes-named", "look",
                        "named volumes no container uses; their data does not come back; `podman volume rm` by hand",
                        how="podman-volume", members=named, alloc=sum(named.values())))
    if used:
        rows.append(Row("Podman volumes in use", "leave", "a container uses them", alloc=used))
    return rows


def container_rows() -> list[Row]:
    names = run(["podman", "ps", "--format", "{{.Names}}"]).split()
    return [Row("Podman running containers", "leave", "in use: " + ", ".join(names))] if names else []


def stopped_container_rows() -> list[Row]:
    """Containers that stopped RECENT or longer ago, as one delete group.

    `podman rm` takes the container's own layer; its volumes stay. A
    container whose process ended but whose cleanup has not run is `stopped`.
    """
    done = [c for c in json.loads(run(["podman", "ps", "-a", "--size", "--format", "json"]))
            if c["State"] in STOPPED and time.time() - c["ExitedAt"] >= RECENT]
    return container_group_rows("podman", {c["Names"][0]: int((c.get("Size") or {}).get("rwSize") or 0)
                                           for c in done})
