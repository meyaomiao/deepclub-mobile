#!/usr/bin/env python3
"""Build the DeepClub runtime overlay from a checksum-pinned upstream runtime APK.

Only runtime assets and the four documented Termux libraries are reused. No APK
DEX, Flutter bundle, restricted artwork or phone-control implementation is copied.
The original runtime build recipe remains in the reconstructed upstream source.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import lzma
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ROOT = "opt/dsh-go/deepclub-tools"
PATCH_PATH = "etc/dsh-app/dsh-web.patch.yml"
RUNTIME_INFO = "etc/dsh-app/runtime.json"
PRESET_PATCHES = {
    "opt/dsh/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml": (
        "3006cc3780cddaa7fb0089e5854e6bbef4409cf1d425930fd835226b95660afd",
        "d7ac1fea64369fb9340013833bfb8960ebcad25c4747c9598362c918dd58f005",
    ),
    "opt/dsh/node_modules/@deepseek-ai/dsh-web-app/presets/ptc.patch.yml": (
        "ce02148b1fd575cc93071744180468cd305bdcd50dbfdd3b9b0605c5281d283d",
        "d8b1058efc2d376f5c0b769cbbeb0702d79476cbacae5b3c3c6cad670d3af150",
    ),
    "opt/dsh/node_modules/@deepseek-ai/dsh-web-app/presets/cordis.patch.yml": (
        "0e8f611644b3c36249808c4d7eb7a40d78006d04da6b55eef1a42797a5a34355",
        "ddf3f4eced54951d06443388646b1ca4791b1bcde5e9a455a1793d8c1e1eee3c",
    ),
}
WEB_TOOL_BLOCK = (
    "          - id: tool-web\n"
    "            name: '@deepseek-ai/dsh-tool-web'\n"
    "            config:\n"
    "              fetch: true\n"
    "              searchTimeoutMs: 60000\n"
)


class HashingWriter:
    def __init__(self, stream):
        self.stream = stream
        self.digest = hashlib.sha256()
        self.size = 0

    def write(self, data):
        self.digest.update(data)
        self.size += len(data)
        return self.stream.write(data)

    def flush(self):
        self.stream.flush()


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_output(root: Path, relative: str) -> Path:
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()):
        raise SystemExit(f"Output escapes build directory: {relative}")
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def add_file(archive, name, data, epoch, mode=0o644):
    info = tarfile.TarInfo(name)
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime, info.mode, info.size = epoch, mode, len(data)
    archive.addfile(info, io.BytesIO(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--apk", required=True, type=Path)
    args = parser.parse_args()
    checkout, apk = args.checkout.resolve(), args.apk.resolve()
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    source = lock["runtimeSource"]
    if apk.stat().st_size != source["bytes"] or sha256(apk) != source["sha256"]:
        raise SystemExit("Upstream APK does not match the pinned SHA-256 and length.")
    plugin = checkout / "runtime/deepclub-tools"
    if not (plugin / "src/index.js").is_file():
        raise SystemExit("Prepare the source adaptation before preparing its runtime.")
    files = sorted(path for path in plugin.rglob("*") if path.is_file()
                   and not any(part in {"node_modules", "test"} for part in path.relative_to(plugin).parts))
    if any(path.is_symlink() for path in files):
        raise SystemExit("Unexpected symlink in plugin source files.")
    revision = hashlib.sha256()
    revision.update(Path(__file__).read_bytes())
    revision.update((ROOT / "upstream.lock.json").read_bytes())
    for path in files:
        revision.update(str(path.relative_to(plugin)).encode())
        revision.update(path.read_bytes())
    version = "deepclub-1-" + revision.hexdigest()[:12]
    preset_evidence = {name: {"before_sha256": pair[0], "sha256": pair[1]} for name, pair in PRESET_PATCHES.items()}
    target = checkout / "runtime/out" / source["abi"]
    target.mkdir(parents=True, exist_ok=True)
    cache = ROOT / ".cache"
    cache.mkdir(exist_ok=True)
    original = cache / "upstream-rootfs-arm64-v8a.tar.xz"

    with zipfile.ZipFile(apk) as bundle:
        manifest = json.loads(bundle.read("assets/runtime/manifest.json"))
        if manifest["schema"] != 1 or manifest["abi"] != "arm64-v8a" or manifest["dshVersion"] != lock["dsh"]:
            raise SystemExit("Unsupported pinned runtime contract.")
        rootfs_name = manifest["rootfs"]
        if rootfs_name != "rootfs-arm64-v8a.tar.xz":
            raise SystemExit("Unexpected upstream runtime archive name.")
        if not original.exists() or sha256(original) != manifest["rootfsSha256"]:
            with bundle.open("assets/runtime/" + rootfs_name) as src, original.open("wb") as dst:
                shutil.copyfileobj(src, dst)
        if sha256(original) != manifest["rootfsSha256"]:
            raise SystemExit("The extracted rootfs checksum is invalid.")
        for library, metadata in manifest["jniLibs"].items():
            if library not in {"libproot.so", "libproot-loader.so", "libtalloc.so", "libandroid-shmem.so"}:
                raise SystemExit("Unexpected native runtime library.")
            content = bundle.read(f"lib/arm64-v8a/{library}")
            if hashlib.sha256(content).hexdigest() != metadata["sha256"]:
                raise SystemExit(f"Native library checksum mismatch: {library}")
            output = safe_output(target, f"jniLibs/arm64-v8a/{library}")
            output.write_bytes(content)
            output.chmod(0o755)
        for name in bundle.namelist():
            if name.startswith("assets/runtime/licenses/") and not name.endswith("/"):
                if ".." in PurePosixPath(name).parts:
                    raise SystemExit("Unsafe runtime license path.")
                safe_output(target, name).write_bytes(bundle.read(name))

    # Keep the app bridge but omit its companion presets. Providers and tools
    # get their mutable catalog from account sync, never from this static patch.
    patch = """# DeepClub Android runtime; generated from the reviewed adaptation.
- id: llm-deepseek-account
  disabled: true
- id: llm-deepseek
  disabled: true
- id: session-log-deepseek
  disabled: true
- id: plugin-market
  disabled: true
- id: tool-plugin-market
  disabled: true
- id: tool-web
  config:
    search: false
    fetch: true
- id: web-search-deepseek
  disabled: true
- id: web-deepseek-api
  disabled: true
- id: session-telemetry-otel
  disabled: true
- id: dsh-media
  disabled: true
- insert:
    - id: dsh-go-bridge
      name: /opt/dsh-go/dsh-go-bridge/lib/index.js
# deepclub-tools is registered by native bootstrap in the writable web profile.
# A CLI-layer insert would prevent settings/mutate from updating its catalog.
""".encode()
    output = safe_output(target, "assets/runtime/" + rootfs_name)
    epoch = manifest.get("build", {}).get("sourceDateEpoch", 1767225600)
    counts = {"dir": 0, "file": 0, "symlink": 0}
    uncompressed = 0
    found = set()
    with lzma.open(output, "wb", preset=6) as compressed:
        writer = HashingWriter(compressed)
        with tarfile.open(original, "r|xz") as incoming, tarfile.open(fileobj=writer, mode="w|", format=tarfile.GNU_FORMAT) as outgoing:
            for entry in incoming:
                path = PurePosixPath(entry.name)
                if path.is_absolute() or ".." in path.parts:
                    raise SystemExit("Unsafe path in pinned runtime archive.")
                if entry.name == PLUGIN_ROOT or entry.name.startswith(PLUGIN_ROOT + "/"):
                    raise SystemExit("Pinned runtime unexpectedly contains DeepClub tools.")
                if entry.isfile():
                    counts["file"] += 1
                    stream = incoming.extractfile(entry)
                    if entry.name == PATCH_PATH:
                        add_file(outgoing, entry.name, patch, epoch)
                        uncompressed += len(patch)
                        found.add(PATCH_PATH)
                    elif entry.name == RUNTIME_INFO:
                        info = json.load(stream)
                        info["runtimeVersion"] = version
                        info["deepclub"] = {"sourceAPK": source["sha256"], "overlayRevision": revision.hexdigest(), "presetPatches": preset_evidence}
                        content = (json.dumps(info, indent=2, sort_keys=True) + "\n").encode()
                        add_file(outgoing, entry.name, content, epoch)
                        uncompressed += len(content)
                        found.add(RUNTIME_INFO)
                    elif entry.name in PRESET_PATCHES:
                        content = stream.read()
                        before, after = PRESET_PATCHES[entry.name]
                        if hashlib.sha256(content).hexdigest() != before:
                            raise SystemExit(f"Pinned preset changed: {entry.name}")
                        text = content.decode("utf-8")
                        if text.count(WEB_TOOL_BLOCK) != 1:
                            raise SystemExit(f"Expected exactly one web-tool block: {entry.name}")
                        replacement = WEB_TOOL_BLOCK.replace("              fetch: true\n", "              fetch: true\n              search: false\n")
                        content = text.replace(WEB_TOOL_BLOCK, replacement).encode("utf-8")
                        if hashlib.sha256(content).hexdigest() != after:
                            raise SystemExit(f"Preset adaptation digest mismatch: {entry.name}")
                        add_file(outgoing, entry.name, content, epoch)
                        uncompressed += len(content)
                        found.add(entry.name)
                    else:
                        outgoing.addfile(entry, stream)
                        uncompressed += entry.size
                elif entry.isdir():
                    counts["dir"] += 1
                    outgoing.addfile(entry)
                elif entry.issym():
                    counts["symlink"] += 1
                    outgoing.addfile(entry)
                else:
                    raise SystemExit("Unexpected special entry in pinned runtime.")
            if found != {PATCH_PATH, RUNTIME_INFO, *PRESET_PATCHES}:
                raise SystemExit("Pinned runtime overlay and preset inputs were not found.")
            directories = {PLUGIN_ROOT}
            for path in files:
                parent = PurePosixPath(PLUGIN_ROOT, path.relative_to(plugin).as_posix()).parent
                while str(parent).startswith(PLUGIN_ROOT):
                    directories.add(str(parent))
                    parent = parent.parent
            for directory in sorted(directories, key=lambda value: value.split("/")):
                info = tarfile.TarInfo(directory)
                info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, epoch
                info.uid = info.gid = 0
                outgoing.addfile(info)
                counts["dir"] += 1
            for path in files:
                content = path.read_bytes()
                add_file(outgoing, PLUGIN_ROOT + "/" + path.relative_to(plugin).as_posix(), content, epoch)
                counts["file"] += 1
                uncompressed += len(content)
            info = tarfile.TarInfo(PLUGIN_ROOT + "/node_modules")
            info.type, info.mode, info.mtime = tarfile.SYMTYPE, 0o777, epoch
            info.linkname = "../../dsh/node_modules"
            outgoing.addfile(info)
            counts["symlink"] += 1
    manifest.update(runtimeVersion=version, rootfsSha256=sha256(output), rootfsBytes=output.stat().st_size,
                    tarBytes=writer.size, tarSha256=writer.digest.hexdigest(), uncompressedBytes=uncompressed, entries=counts)
    manifest["deepclub"] = {"sourceAPK": source["sha256"], "overlayRevision": revision.hexdigest(), "presetPatches": preset_evidence}
    manifest["archiveNotes"] += "; DeepClub tools appended with explicit parent directories"
    safe_output(target, "assets/runtime/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {version}: {output} sha256={manifest['rootfsSha256']}")


if __name__ == "__main__":
    main()
