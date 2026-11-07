import math
import os
import subprocess
import time


def git(directory, *args, deadline=math.inf):
    """The output of git run in directory, or None when it fails or when the time.monotonic() value deadline leaves no
    time; a run is cut at 3 s or at the deadline."""
    timeout = min(3, deadline - time.monotonic())
    if timeout <= 0:
        return None
    try:
        p = subprocess.run(["git", "-C", directory, *args], capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def is_shared_checkout(directory, deadline=math.inf):
    dirs = git(directory, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", deadline=deadline)
    if dirs is None or git(directory, "rev-parse", "--is-bare-repository", deadline=deadline) != "false":
        return False
    lines = dirs.splitlines()
    if len(lines) != 2 or lines[0] != lines[1]:
        return False
    git_dir = os.path.realpath(lines[0])
    home = os.path.realpath(os.path.expanduser("~")) + os.sep
    tmpdir = os.path.realpath(os.environ.get("TMPDIR") or "/tmp") + os.sep
    tmpdir_holds_home = home.startswith(tmpdir)
    scratch = [os.path.realpath("/tmp") + os.sep] + ([] if tmpdir_holds_home else [tmpdir])
    return not any(git_dir.startswith(d) for d in scratch)
