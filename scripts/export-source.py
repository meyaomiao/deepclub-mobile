#!/usr/bin/env python3
"""Export the modified build source and its adaptation layer without private inputs or restricted extras."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = "app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/"
EXCLUDED = (
    "app/assets/whale/", "app/assets/pets/", "app/assets/star/", "app/assets/companion/",
    "app/tool/pet_src/", "app/tool/whale_src/", "docs/assets/", "site/home/",
    NATIVE + "phone/", NATIVE + "pet/", NATIVE + "companion/", NATIVE + "update/privileged/",
    NATIVE + "runtime/PhoneSkill",
)
EXCLUDED_BRAND = {"app/assets/brand/glyph-dark.svg", "app/assets/brand/glyph-light.svg",
                  "app/assets/brand/glyph-mono.svg", "app/assets/brand/tile.svg"}


def files(root: Path) -> list[str]:
    result = subprocess.check_output(["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    return sorted({item.decode() for item in result.split(b"\0") if item})


def add_bytes(archive, name, data, mode=0o644):
    info = tarfile.TarInfo(name)
    info.size, info.mode, info.mtime = len(data), mode, 0
    archive.addfile(info, io.BytesIO(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    assert subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip() == lock["commit"]
    expected = json.loads((ROOT / "overlay/source-state.json").read_text())
    for name, value in expected.items():
        path = checkout / name
        actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        assert actual == value, f"Changed after capture: {name}"
    source_id = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
    destination = args.out.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    manifest = {}
    with tarfile.open(destination, "w:gz", format=tarfile.GNU_FORMAT) as archive:
        for name in files(checkout):
            path = checkout / name
            if name.startswith(EXCLUDED) or name in EXCLUDED_BRAND or not path.exists():
                continue
            if any(part in {"node_modules", ".dart_tool", ".cache", "build"} for part in Path(name).parts):
                continue
            if name.endswith(("key.properties", ".apk", ".p12", ".jks", ".keystore", ".credentials.yaml")):
                raise SystemExit(f"Private/generated source input: {name}")
            if path.is_symlink():
                assert path.resolve().is_relative_to(checkout), name
                archive.add(path, arcname="deepclub-agent-source/" + name, recursive=False)
            elif path.is_file():
                data = path.read_bytes()
                manifest[name] = hashlib.sha256(data).hexdigest()
                add_bytes(archive, "deepclub-agent-source/" + name, data, path.stat().st_mode & 0o777)
        for name in files(ROOT):
            path = ROOT / name
            if path.is_file() and not path.is_symlink() and not name.startswith(("dist/", ".work/", ".cache/")):
                add_bytes(archive, "deepclub-agent-source/DEEPCLUB_ADAPTATION/" + name, path.read_bytes(), path.stat().st_mode & 0o777)
        add_bytes(archive, "deepclub-agent-source/DEEPCLUB_SOURCE.json", (json.dumps({
            "adaptation_commit": source_id, "upstream_commit": lock["commit"],
            "excluded_non_distributed_paths": list(EXCLUDED) + sorted(EXCLUDED_BRAND), "sha256": manifest,
        }, indent=2, sort_keys=True) + "\n").encode())
        add_bytes(archive, "deepclub-agent-source/DEEPCLUB_BUILD.md", (
            "# DeepClub modified source\n\n"
            "This is the complete modified source used for the first Android build, excluding non-distributed restricted artwork and phone-control sources.\n\n"
            "Upstream licenses and attribution remain. The adaptation, immutable inputs and build instructions are in DEEPCLUB_ADAPTATION/. "
            "The upstream README and contribution policy describe upstream, while DeepClub contributions target meyaomiao/deepclub-mobile.\n\n"
            "This export has no .git directory. You may reconstruct a Git checkout with DEEPCLUB_ADAPTATION/scripts/prepare.py, or build this tree directly: "
            "prepare its runtime with prepare-runtime.py, run Flutter pub get --enforce-lockfile and tool/l10n_merge.py in app/, configure your own ignored signing inputs, "
            "then run bash tooling/build-apk.sh --release --flavor arm64 --build-name 0.1.0. "
            "No signing key or account credential is included. See DEEPCLUB_SOURCE.json for exact source identity and file hashes.\n"
        ).encode())
    with destination.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    destination.with_name(destination.name + ".sha256").write_text(f"{digest}  {destination.name}\n")
    print(f"Exported {len(manifest)} source files: {destination} SHA-256 {digest}")


if __name__ == "__main__":
    main()
