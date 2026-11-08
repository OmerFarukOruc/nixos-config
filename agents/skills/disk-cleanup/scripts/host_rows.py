"""Rows for the Nix store, the boot partition, the Brave model, and a failing command."""

import glob
import json
import os

from config import NIX_STORE
from holders import HOME
from measure import du_size
from rows import CommandError, Row, run


def side_rows(label: str, source) -> list[Row]:
    """Rows from another tool; a failing command becomes a look row that quotes it."""
    try:
        return source()
    except CommandError as e:
        return [Row(label, "look", str(e))]


def boot_rows() -> list[Row]:
    """The ESP and the system generations whose kernels it holds.

    angrr picks the generations (nixosModules/common.nix in nixos-config), so
    this row only reports them. `/boot` is not readable without root, so the
    count comes from the system profile links.
    """
    generations = len(glob.glob("/nix/var/nix/profiles/system-*-link"))
    used = int(run(["df", "-B1", "--output=used", "/boot"]).split()[-1])
    return [Row("`/boot` and generations", "leave",
                f"{generations} system generations; angrr drops old ones before each daily nix-gc; "
                f"running {os.uname().release}", alloc=used)]


def nix_rows() -> list[Row]:
    """The Nix store as one leave row: nix-gc runs daily, and angrr drops old system generations first.

    A `result` link or a `.direnv` folder in a work tree keeps its store paths
    out of the GC until the link or folder goes.
    """
    return [Row(NIX_STORE, "leave",
                "the daily nix-gc frees what no GC root keeps; `result` links and `.direnv` folders in work "
                "trees are GC roots", alloc=du_size(NIX_STORE))]


def brave_rows() -> list[Row]:
    base = f"{HOME}/.config/BraveSoftware"
    for prof in os.listdir(base) if os.path.isdir(base) else []:
        try:
            with open(f"{base}/{prof}/Local State") as f:
                switch = json.load(f).get("optimization_guide", {}).get(
                    "on_device_foundational_model_user_settings")
        except (OSError, ValueError):
            continue
        if switch is None and not os.path.isdir(f"{base}/{prof}/OptGuideOnDeviceModel"):
            return [Row("Brave on-device model", "look",
                        "not downloaded, but `optimization_guide.on_device_foundational_model_user_settings` "
                        "is unset, so Brave can still fetch it")]
    return []
