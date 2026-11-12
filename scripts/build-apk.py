#!/usr/bin/env python3
"""Build a pinned DeepClub APK with source identity and explicit signing inputs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--test-origin", help="debug only; the App validates a loopback or emulator origin")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    if args.test_origin and not args.debug:
        raise SystemExit("A test origin is only allowed in a debug build.")
    head = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
    if not args.debug and subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"], text=True).strip():
        raise SystemExit("Commit the reviewed adaptation before building a release with a source URL.")
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    source_head = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if source_head != lock["commit"]:
        raise SystemExit("Source checkout does not match the pinned upstream.")
    expected = json.loads((ROOT / "overlay/source-state.json").read_text())
    changed = subprocess.check_output(["git", "-C", str(checkout), "diff", "--name-only", "--no-renames", "-z", "HEAD"])
    additions = subprocess.check_output(["git", "-C", str(checkout), "ls-files", "--others", "--exclude-standard", "-z"])
    paths = {value.decode() for value in (changed + additions).split(b"\0") if value}
    if paths != set(expected):
        raise SystemExit("Source changes differ from the captured adaptation; review and capture again.")
    for relative, digest in expected.items():
        path = checkout / relative
        actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        if actual != digest:
            raise SystemExit(f"Source changed after review: {relative}")
    android = checkout / "app/android"
    if not args.debug and not (android / "key.properties").is_file():
        raise SystemExit("Configure your own private Android signing key; release builds must not fall back to a debug key.")
    flutter = shutil.which("flutter")
    if flutter is None:
        raise SystemExit("Put Flutter 3.47.7 on PATH.")
    sdk = Path(flutter).resolve().parent.parent
    wrapper = sdk / "bin/cache/artifacts/gradle_wrapper"
    for relative in ("gradlew", "gradlew.bat", "gradle/wrapper/gradle-wrapper.jar"):
        destination = android / relative
        if not destination.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(wrapper / relative, destination)
    (android / "gradlew").chmod(0o755)
    command = ["bash", str(checkout / "tooling/build-apk.sh"), "--debug" if args.debug else "--release",
               "--flavor", "arm64", "--build-name", "0.1.0", "--keep-daemon", "--", "--no-pub",
               f"--dart-define=DEEPCLUB_SOURCE_URL=https://github.com/meyaomiao/deepclub-mobile/tree/{head}"]
    if args.test_origin:
        command.append(f"--dart-define=DEEPCLUB_TEST_ORIGIN={args.test_origin}")
    subprocess.run(command, cwd=checkout, env=os.environ.copy(), check=True)
    mode = "debug" if args.debug else "release"
    built = checkout / f"app/build/app/outputs/flutter-apk/app-arm64-{mode}.apk"
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    name = f"deepclub-agent-0.1.0-arm64-{mode}.apk"
    shutil.copy2(built, output / name)
    with (output / name).open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    (output / (name + ".sha256")).write_text(f"{digest}  {name}\n")
    print(f"Built {name}: SHA-256 {digest}")


if __name__ == "__main__":
    main()
