#!/usr/bin/env python3
"""Reconstruct the pinned, modified source without changing an existing dirty checkout."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(checkout: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", "-C", str(checkout), *arguments], text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, default=ROOT / ".work/dsh-go")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    patch = ROOT / "overlay/deepclub.patch"
    if not patch.is_file():
        raise SystemExit("The reviewed adaptation patch is missing.")
    if checkout.exists():
        if git(checkout, "status", "--porcelain"):
            raise SystemExit("Checkout has changes; choose a new directory instead of overwriting it.")
        if git(checkout, "rev-parse", "HEAD") != lock["commit"]:
            raise SystemExit("Checkout does not match upstream.lock.json.")
    else:
        checkout.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--no-checkout", "--depth", "1", lock["repository"], str(checkout)], check=True)
        subprocess.run(["git", "-C", str(checkout), "fetch", "--depth", "1", "origin", lock["commit"]], check=True)
        subprocess.run(["git", "-C", str(checkout), "checkout", "--detach", lock["commit"]], check=True)
    new_root = ROOT / "overlay/new"
    manifest = json.loads((ROOT / "overlay/files.json").read_text())
    tree = json.loads((ROOT / "overlay/tree.json").read_text())
    additions = sorted(path for path in new_root.rglob("*") if path.is_file())
    if {path.relative_to(new_root).as_posix() for path in additions} != set(manifest):
        raise SystemExit("The new-file layer does not match its manifest.")
    for source in additions:
        relative = source.relative_to(new_root)
        destination = checkout / relative
        if source.is_symlink() or not destination.resolve().is_relative_to(checkout) or destination.exists():
            raise SystemExit(f"Unexpected new-file collision: {relative}")
        if hashlib.sha256(source.read_bytes()).hexdigest() != manifest[relative.as_posix()]:
            raise SystemExit(f"New-file digest mismatch: {relative}")
    asset_inputs = {**tree["removals"], **{name: value["before_sha256"] for name, value in tree["replacements"].items()}}
    for relative, digest in asset_inputs.items():
        destination = checkout / relative
        if destination.is_symlink() or not destination.resolve().is_relative_to(checkout) or not destination.is_file():
            raise SystemExit(f"Unexpected asset path: {relative}")
        if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            raise SystemExit(f"Pinned asset has changed: {relative}")
    for relative, value in tree["replacements"].items():
        source = ROOT / "overlay/replace" / relative
        if source.is_symlink() or not source.resolve().is_relative_to(ROOT / "overlay/replace"):
            raise SystemExit(f"Unexpected replacement path: {relative}")
        if hashlib.sha256(source.read_bytes()).hexdigest() != value["sha256"]:
            raise SystemExit(f"Replacement digest mismatch: {relative}")
    subprocess.run(["git", "-C", str(checkout), "apply", "--check", str(patch)], check=True)
    subprocess.run(["git", "-C", str(checkout), "apply", str(patch)], check=True)
    for source in additions:
        destination = checkout / source.relative_to(new_root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    for relative in tree["removals"]:
        destination = checkout / relative
        # Recheck the exact deletion target immediately before removing it.
        if destination.is_symlink() or not destination.resolve().is_relative_to(checkout):
            raise SystemExit(f"Asset removal escaped checkout: {relative}")
        destination.unlink()
    for relative in tree["replacements"]:
        shutil.copy2(ROOT / "overlay/replace" / relative, checkout / relative)
    print(f"Prepared DeepClub source at {checkout}")
    print("Next, inside the prepared app/: flutter pub get --enforce-lockfile, then python3 tool/l10n_merge.py.")


if __name__ == "__main__":
    main()
