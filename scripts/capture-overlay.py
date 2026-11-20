#!/usr/bin/env python3
"""Capture reviewed source edits into the pinned patch and new-file layer."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--refresh", action="store_true", help="replace this repository's generated new-file layer")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    head = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if head != lock["commit"]:
        raise SystemExit("The source checkout must remain at the pinned upstream commit.")
    overlay = ROOT / "overlay"
    overlay.mkdir(exist_ok=True)
    additions = subprocess.check_output(["git", "-C", str(checkout), "ls-files", "--others", "--exclude-standard", "-z"])
    paths = [value.decode() for value in additions.split(b"\0") if value]
    forbidden = {"node_modules", ".dart_tool", ".cache", "build", "key.properties", ".env", ".credentials.yaml"}
    for value in paths:
        path = PurePosixPath(value)
        source = checkout / value
        if path.is_absolute() or ".." in path.parts or any(part in forbidden for part in path.parts) or path.suffix in {".apk", ".jks", ".keystore", ".p12"}:
            raise SystemExit(f"Unexpected generated or sensitive input: {value}")
        if source.is_symlink() or not source.resolve().is_relative_to(checkout):
            raise SystemExit(f"Unexpected source link: {value}")
    # Git binary patches include reverse data. Store only the replacement bytes
    # and original hashes so upstream restricted artwork is not redistributed.
    stats = subprocess.check_output(["git", "-C", str(checkout), "diff", "--numstat", "--no-renames", "-z", "HEAD"])
    assets = []
    for row in stats.split(b"\0"):
        if not row:
            continue
        added, removed, raw_path = row.split(b"\t", 2)
        value = raw_path.decode()
        suffix = PurePosixPath(value).suffix.lower()
        if added == b"-" or removed == b"-" or suffix in {".svg", ".png", ".webp", ".gif", ".ico", ".icns"} or value.endswith(("brand_glyph.g.dart", "/phone_accessibility_service.xml")) or "/res/drawable" in value or "/res/mipmap" in value:
            assets.append(value)
    for directory in ("new", "replace"):
        target = overlay / directory
        if target.exists():
            if not args.refresh:
                raise SystemExit("Generated overlay exists; review it and pass --refresh to replace it.")
            if target.is_symlink() or target.resolve() != ROOT / "overlay" / directory:
                raise SystemExit("Unexpected overlay path; refusing to remove it.")
            shutil.rmtree(target)
        target.mkdir()
    manifest = {}
    for value in sorted(paths):
        source, destination = checkout / value, overlay / "new" / value
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        manifest[value] = hashlib.sha256(source.read_bytes()).hexdigest()
    tree = {"replacements": {}, "removals": {}}
    for value in sorted(assets):
        original = subprocess.check_output(["git", "-C", str(checkout), "show", "HEAD:" + value])
        before = hashlib.sha256(original).hexdigest()
        source = checkout / value
        if source.exists():
            if source.is_symlink():
                raise SystemExit(f"Unexpected replacement link: {value}")
            destination = overlay / "replace" / value
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            tree["replacements"][value] = {"before_sha256": before, "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
        else:
            tree["removals"][value] = before
    patch = subprocess.check_output(["git", "-C", str(checkout), "diff", "--no-renames", "HEAD", "--", ".", *[":(exclude)" + value for value in assets]])
    (overlay / "deepclub.patch").write_bytes(patch)
    (overlay / "files.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (overlay / "tree.json").write_text(json.dumps(tree, indent=2, sort_keys=True) + "\n")
    changed = subprocess.check_output(["git", "-C", str(checkout), "diff", "--name-only", "--no-renames", "-z", "HEAD"])
    source_paths = set(paths) | {value.decode() for value in changed.split(b"\0") if value}
    state = {value: hashlib.sha256((checkout / value).read_bytes()).hexdigest() if (checkout / value).is_file() else None for value in sorted(source_paths)}
    (overlay / "source-state.json").write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    print(f"Captured {len(paths)} new files, {len(assets)} asset changes and {len(patch)} text patch bytes.")


if __name__ == "__main__":
    main()
