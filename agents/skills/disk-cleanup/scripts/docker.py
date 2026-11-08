"""Rows for Docker images, volumes, build cache, and containers."""

import datetime
import functools
import json
import os
import re
import shutil
import subprocess
import time
from collections.abc import Callable
from typing import NamedTuple

from activity import session_mentions
from config import FLOOR, RECENT, SCAN
from holders import inside
from measure import du_size
from rows import CommandError, Row, day, run


def si_bytes(text: str) -> int:
    """Bytes in a size docker prints, such as "41.6MB"; docker uses SI units."""
    m = re.match(r"([\d.]+)\s*([kMGT]?B)", text)
    return int(float(m.group(1)) * {"B": 1, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}[m.group(2)]) if m else 0


# Docker keeps its data in its root directory (`docker info`), whose files belong to root, or to
# subordinate uids for rootless Docker, so FIEMAP cannot estimate it.
BOUND_NOTE = ("A Docker row shows Docker's own size, an upper bound: two Docker build cache "
              "prunes dropped `df` by 0.58 and 0.67 of it.")
ANONYMOUS = "com.docker.volume.anonymous"
# Where the Docker CLI looks with no DOCKER_HOST or context, then where rootless Docker listens:
# https://docs.docker.com/reference/cli/docker/#environment-variables and
# https://docs.docker.com/engine/security/rootless/tips/
ROOTFUL_SOCKET = "/var/run/docker.sock"
ROOTLESS_SOCKET = f"{os.environ.get('XDG_RUNTIME_DIR') or f'/run/user/{os.getuid()}'}/docker.sock"


def docker_host() -> str | None:
    """The endpoint the Docker CLI would use, or None when it would use a socket that does not exist.

    A bare `docker context inspect` resolves DOCKER_HOST, DOCKER_CONTEXT, and
    a context saved by `docker context use` as the CLI does. Without them it
    names ROOTFUL_SOCKET, so a rootless daemon over `ssh`, where
    XDG_RUNTIME_DIR is empty, needs the fallback to ROOTLESS_SOCKET.
    """
    host = run(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]).strip()
    if host != f"unix://{ROOTFUL_SOCKET}" or os.path.exists(ROOTFUL_SOCKET):
        return host
    return f"unix://{ROOTLESS_SOCKET}" if os.path.exists(ROOTLESS_SOCKET) else None


class Docker(NamedTuple):
    host: str | None
    root: str | None
    source: Callable[[], list[Row]]


def docker() -> Docker:
    """Pin every later docker command to one local endpoint, and read the daemon's root directory."""
    def unmeasured(reason: str) -> Callable[[], list[Row]]:
        return lambda: [Row("Docker", "look", reason)]
    if not shutil.which("docker"):
        return Docker(None, None, list)
    try:
        host = docker_host()
    except CommandError as e:
        return Docker(None, None, unmeasured(str(e)))
    if host is None:
        return Docker(None, None, unmeasured(f"no daemon answers at `{ROOTFUL_SOCKET}` or `{ROOTLESS_SOCKET}`; "
                                             "not measured"))
    if not host.startswith("unix://"):
        return Docker(host, None, unmeasured(f"`{host}` is not a local socket; not measured"))
    os.environ["DOCKER_HOST"] = host
    os.environ.pop("DOCKER_CONTEXT", None)
    try:
        root = run(["docker", "info", "--format", "{{.DockerRootDir}}"]).strip()
    except CommandError as e:
        return Docker(host, None, unmeasured(str(e)))
    return Docker(host, root, docker_rows)


def docker_root_rows(sizes: dict[str, int], root: str) -> list[Row]:
    """Take the Docker root's bytes out of every scanned size; one leave row holds them when they reach the floor.

    `du -x` counted them only when the root is on the filesystem of the scan root that holds it.
    """
    try:
        b = du_size(root)
    except CommandError:
        b = 0
    top = next(t for t in SCAN if inside(root, t))
    if os.lstat(root).st_dev == os.lstat(top).st_dev:
        for path in list(sizes):
            if inside(path, root):
                del sizes[path]
            elif inside(root, path):
                sizes[path] -= b
    return [Row(root, "leave", "Docker's data; the Docker rows measure it", alloc=b)] if b >= FLOOR else []


def docker_rows() -> list[Row]:
    """Rows for Docker images, volumes, build cache, and containers.

    The survey reads only local state; remove.py asks each registry before a
    pulled image goes.
    """
    return [*image_rows(), *volume_rows(), *build_cache_rows(), *container_rows(), *stopped_container_rows()]


def image_rows() -> list[Row]:
    """Unused pulled and untagged images as delete groups, and every other unused image as a look row.

    An image is pulled when its index lists a platform whose content is not
    here, which only a pull leaves; a local build has every manifest it
    lists. A single-platform pull looks like a local build and lands on look.
    This host uses the containerd image store, where an untagged image's
    references are all `repo@digest`, `docker images` shows it as
    `repo:<none>`, and `docker image prune` keeps it, so rows name each image
    by reference: its first tag, else `repo@digest`.

    An untagged image with a registry digest, made RECENT or longer ago,
    goes in group:docker-untagged unless a running agent named it; nothing
    refers to it by name, and remove.py asks the registry for its digest
    first. An untagged image without a digest has no registry copy, so it
    stays on look.
    """
    use = {i["ID"]: (int(i["Containers"] or 0), si_bytes(i["UniqueSize"])) for i in docker_df()["Images"] or []}
    images = json.loads(run(["curl", "-sf", "--unix-socket", os.environ["DOCKER_HOST"].removeprefix("unix://"),
                             "http://docker/images/json?manifests=1"]))
    pulled, untagged, builds = {}, {}, []
    for i in images:
        containers, b = use.get(i["Id"], (1, 0))
        if containers:
            continue
        ref = next(iter(i.get("RepoTags") or i.get("RepoDigests") or []), i["Id"][7:19])
        if untagged_image(i) and i.get("RepoDigests") and 0 < i["Created"] <= time.time() - RECENT:
            untagged[ref] = (i, b)
        elif any(not m["Available"] for m in i.get("Manifests") or []):
            pulled[ref] = b
        else:
            builds.append((ref, i, b))
    rows = [Row("group:docker-images", "delete", "unused pulled images; `docker pull` brings each back",
                how="docker-image", members=pulled, alloc=sum(pulled.values()), frees=sum(pulled.values()),
                bound=True)] if pulled else []
    named = session_mentions([*untagged, *(ref for ref, *_ in builds)])
    rows += [Row(f"Docker image `{ref}`", "look",
                 f"untagged image made {day(i['Created'])}; no container uses it; {named[ref]}", alloc=b)
             for ref, (i, b) in untagged.items() if ref in named]
    old = {ref: b for ref, (_, b) in untagged.items() if ref not in named}
    if old:
        rows.append(Row("group:docker-untagged", "delete",
                        "untagged images no container uses, made 24+ h ago; nothing names them, "
                        "and a pull by digest brings each back",
                        how="docker-untagged", members=old, alloc=sum(old.values()), frees=sum(old.values()),
                        bound=True))
    for ref, i, b in builds:
        rows.append(Row(f"Docker image `{ref}`", "look", build_evidence(ref, i, named.get(ref)), alloc=b))
    return rows


def untagged_image(image: dict) -> bool:
    return all("@" in ref for ref in image.get("RepoTags") or [])


@functools.cache
def docker_df() -> dict:
    """`docker system df -v`: Images, Containers, Volumes, and BuildCache."""
    return json.loads(run(["docker", "system", "df", "-v", "--format", "{{json .}}"]))


def dangling_volumes() -> set[str]:
    return set(run(["docker", "volume", "ls", "-q", "-f", "dangling=true"]).split())


def created(volume: dict) -> float:
    return datetime.datetime.fromisoformat(volume["CreatedAt"]).timestamp()


def build_evidence(ref: str, image: dict, named: str | None) -> str:
    """What decides whether a local build can go, for Omer to check by hand."""
    labels = image.get("Labels") or {}
    tag = ref.rpartition(":")[2] if "@" not in ref else ""
    if project := labels.get("com.docker.compose.project"):
        source = f"compose project `{project}` service `{labels.get('com.docker.compose.service')}` rebuilds it"
    elif re.fullmatch(r"[0-9a-f]{7,40}", tag):
        source = f"its tag is commit `{tag[:8]}`; it can go when that commit is on `origin`"
    else:
        source = "check that a script or CI rebuilds it"
    return "; ".join([f"local build of {day(image['Created'])}", source, "no container uses it",
                      named or "no running agent named it in 24 h", "`docker rmi` by hand"])


def volume_rows() -> list[Row]:
    """Old orphaned anonymous volumes on delete, young ones on look, named volumes on leave.

    An anonymous volume belongs to the container that made it; once that
    container is gone, no compose file can attach it again. The 78 removed
    on 28-09-2026 held test Postgres data, node_modules, and docker-in-docker
    state. A named volume holds a compose project's data.
    """
    names = run(["docker", "volume", "ls", "-q"]).split()
    if not names:
        return []
    sizes = {v["Name"]: si_bytes(v["Size"]) for v in docker_df()["Volumes"] or []}
    dangling = dangling_volumes()
    old, young, kept, projects = {}, {}, 0, set()
    for v in json.loads(run(["docker", "volume", "inspect", *names])):
        labels, name = v.get("Labels") or {}, v["Name"]
        if ANONYMOUS not in labels:
            kept += sizes.get(name, 0)
            projects.add(labels.get("com.docker.compose.project") or name)
        elif name in dangling:
            (young if time.time() - created(v) < RECENT else old)[name] = sizes.get(name, 0)
    rows = []
    if old:
        rows.append(Row("group:docker-volumes", "delete",
                        "anonymous volumes no container uses, created 24+ h ago; nothing attaches them again",
                        how="docker-volume", members=old, alloc=sum(old.values()), frees=sum(old.values()),
                        bound=True))
    if young:
        rows.append(Row("group:docker-volumes-recent", "look",
                        "anonymous volumes no container uses, created within 24 h; work may still use them",
                        how="docker-volume", members=young, alloc=sum(young.values())))
    if projects:
        shown = ", ".join(f"`{p}`" for p in sorted(projects)[:3])
        more = f", and {len(projects) - 3} more" if len(projects) > 3 else ""
        rows.append(Row("Docker named volumes", "leave", f"data for {shown}{more}", alloc=kept))
    return rows


def build_cache_rows() -> list[Row]:
    """Build cache records the 24 h prune can free; `docker builder prune` runs after the image rows.

    remove.py prunes with `--filter until=24h`. BuildKit keeps a record in
    use, one used within that window, and every record such a record builds
    on, its `Parent` chain. A record never used counts as old. A shared
    record frees nothing while an image holds it, so it does not count, as in
    Docker's own Reclaimable. On 29-10-2026, counting every old record gave
    11.3 GiB while the prune freed 0.36 GB, because recent records built on
    old ones. Records shared with a removed image only become reclaimable
    after the image goes, which freed another 8.5 GB on 28-09-2026, so
    remove.py runs this row last.
    """
    now, records = time.time(), docker_df()["BuildCache"] or []
    kept = [r["ID"] for r in records if r["InUse"] == "true"
            or (r.get("LastUsedAt") and now - buildkit_time(r["LastUsedAt"]) < RECENT)]
    parents = {r["ID"]: [p for p in (r.get("Parent") or "").split(",") if p] for r in records}
    held, stack = set(kept), kept
    while stack:
        for p in parents.get(stack.pop(), []):
            if p not in held:
                held.add(p)
                stack.append(p)
    b = sum(si_bytes(r["Size"]) for r in records if r["ID"] not in held and r["Shared"] != "true")
    if b < FLOOR:
        return []
    return [Row("Docker build cache", "delete",
                "the next build; records used within 24 h and what they build on stay, "
                "and more becomes reclaimable after images go",
                how="docker-builder", alloc=b, frees=b, bound=True)]


def buildkit_time(text: str) -> float:
    """Seconds since the epoch from a time such as `2026-10-23 11:24:26.37115936 +0000 UTC`."""
    return datetime.datetime.fromisoformat(text.removesuffix(" UTC").replace(" +", "+")).timestamp()


def container_rows() -> list[Row]:
    names = run(["docker", "ps", "--format", "{{.Names}}"]).split()
    return [Row("Running containers", "leave", "in use: " + ", ".join(names))] if names else []


def stopped_container_rows() -> list[Row]:
    """Containers that exited RECENT or longer ago, as one delete group.

    `docker rm` takes the container's own layer, the files it wrote outside
    its volumes; its volumes stay.
    """
    exited = {c["Names"]: si_bytes(c["Size"]) for c in docker_df()["Containers"] or [] if c["State"] == "exited"}
    if not exited:
        return []
    old = {n: exited[n] for n, done in finished(list(exited)).items() if n in exited and time.time() - done >= RECENT}
    if not old:
        return []
    return [Row("group:docker-containers", "delete",
                "containers that exited 24+ h ago; the command that made each makes a new one, "
                "but files written inside the container do not come back",
                how="docker-container", members=old, alloc=sum(old.values()), frees=sum(old.values()), bound=True)]


def finished(names: list[str]) -> dict[str, float]:
    """When each named container exited, in seconds since the epoch.

    `docker inspect` exits 1 when one name is gone since `docker system df`
    and still prints the others; a missing one stays out.
    """
    out = subprocess.run(["docker", "inspect", "--format", "{{.Name}} {{.State.FinishedAt}}", "--", *names],
                         capture_output=True, text=True, check=False).stdout
    return {n.lstrip("/"): datetime.datetime.fromisoformat(t).timestamp()
            for n, t in (line.split(" ", 1) for line in out.splitlines())}
