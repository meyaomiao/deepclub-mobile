#!/usr/bin/env python3
"""Check the built APK's identity, signature, restricted assets and native classes."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import zipfile


def dex_classes(data: bytes) -> list[str]:
    if not data.startswith(b"dex\n"):
        raise ValueError("Unsupported DEX container")
    strings, strings_off = struct.unpack_from("<II", data, 56)
    types, types_off = struct.unpack_from("<II", data, 64)
    count, offset = struct.unpack_from("<II", data, 96)
    result = []
    for index in range(count):
        type_id = struct.unpack_from("<I", data, offset + index * 32)[0]
        assert type_id < types
        string_id = struct.unpack_from("<I", data, types_off + type_id * 4)[0]
        assert string_id < strings
        position = struct.unpack_from("<I", data, strings_off + string_id * 4)[0]
        # Skip the unsigned LEB128 UTF-16 length; class descriptors are ASCII.
        for _ in range(5):
            value = data[position]
            position += 1
            if value < 128:
                break
        else:
            raise ValueError("Invalid DEX string length")
        end = data.index(0, position)
        result.append(data[position:end].decode("utf-8", errors="replace"))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--build-tools", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--mapping", type=Path, help="R8 mapping from this exact release build, when minified")
    args = parser.parse_args()
    apk = args.apk.resolve()
    badging = subprocess.check_output([str(args.build_tools / "aapt2"), "dump", "badging", str(apk)], text=True)
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    assert package and package[1] == "net.deepclub.agent", "Wrong Android package identity"
    assert package[3] == "0.1.0", "Wrong product version"
    labels = dict(re.findall(r"^application-label(?:-([^:]+))?:'([^']*)'$", badging, re.M))
    assert labels and all(label == "DeepClub" for label in labels.values()), "App display name must be DeepClub in every locale"
    launchers = re.findall(r"^launchable-activity:.*? label='([^']*)'", badging, re.M)
    assert launchers and all(label == "DeepClub" for label in launchers), "Wrong launcher display name"
    minimum = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'$", badging, re.M)
    assert minimum and int(minimum[1]) == 26, "Wrong minimum Android SDK"
    assert "targetSdkVersion:'28'" in badging
    assert "native-code: 'arm64-v8a'" in badging
    signature = subprocess.check_output([str(args.build_tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)], text=True)
    assert "Verified using v2 scheme (APK Signature Scheme v2): true" in signature
    forbidden_prefixes = (
        "assets/flutter_assets/assets/whale/", "assets/flutter_assets/assets/pets/",
        "assets/flutter_assets/assets/star/", "assets/flutter_assets/assets/companion/",
    )
    root = "Lio/github/ccch1mneyyy/dsh_app/"
    forbidden_classes = tuple(root + name for name in ("phone/", "pet/", "companion/", "update/privileged/", "runtime/PhoneSkill"))
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        assert not [name for name in names if name.startswith(forbidden_prefixes)], "Restricted art is packaged"
        assert not [name for name in names if name.endswith(("key.properties", ".jks", ".p12", ".keystore", ".credentials.yaml"))], "Private material is packaged"
        assert "assets/flutter_assets/assets/licenses/deepclub-agpl-3.0.txt" in names
        assert "assets/flutter_assets/assets/engine/deepclub/prepare-profile.mjs" in names
        assert "assets/flutter_assets/assets/engine/deepclub/clear-credentials.mjs" in names
        definitions = []
        mapping_ids = set()
        for name in names:
            if re.fullmatch(r"classes\d*\.dex", name):
                dex = archive.read(name)
                definitions.extend(dex_classes(dex))
                mapping_ids.update(value.decode("ascii") for value in re.findall(rb'"pg-map-id"\s*:\s*"([0-9a-f]+)"', dex))
        forbidden = [name for name in definitions if name.startswith(forbidden_classes)]
        assert not forbidden, forbidden
        mapping = args.mapping.read_text() if args.mapping else ""
        mapping_id = re.search(r"^# pg_map_id: ([0-9a-f]+)$", mapping, re.M) if mapping else None
        if mapping_ids:
            assert mapping_id and mapping_ids == {mapping_id[1]}, "R8 mapping does not belong to this APK"
        if mapping:
            assert mapping_id and mapping_ids, "No matching R8 marker in the APK"
            assert not re.search(r"\bio\.github\.ccch1mneyyy\.dsh_app\.(?:phone\.|pet\.|companion\.|update\.privileged\.|runtime\.PhoneSkill)", mapping), "Excluded implementation occurs in the release mapping"
        shim_found = any("/disabled/PhonePlugin;" in name for name in definitions) or "io.github.ccch1mneyyy.dsh_app.disabled.PhonePlugin ->" in mapping
        assert shim_found, "Supply the exact R8 mapping if the unavailable-only shim was renamed"
        runtime = json.loads(archive.read("assets/runtime/manifest.json"))
        payload = archive.read("assets/runtime/" + runtime["rootfs"])
        assert hashlib.sha256(payload).hexdigest() == runtime["rootfsSha256"]
        assert len(runtime["deepclub"]["presetPatches"]) == 3
    with apk.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    certificate = re.search(r"Signer #1 certificate SHA-256 digest: ([a-f0-9]+)", signature)
    report = {
        "apk": apk.name, "sha256": digest, "bytes": apk.stat().st_size,
        "package": package[1], "version_code": int(package[2]), "version_name": package[3],
        "application_labels": labels, "launcher_labels": launchers,
        "min_sdk": 26, "signature_v2_verified": True,
        "signer_certificate_sha256": certificate[1] if certificate else None,
        "restricted_art_entries": 0, "excluded_native_class_definitions": 0,
        "dex_class_definitions_checked": len(definitions), "release_mapping_checked": bool(mapping),
        "r8_mapping_id": mapping_id[1] if mapping_id else None,
        "runtime_version": runtime["runtimeVersion"],
        "runtime_archive_sha256": runtime["rootfsSha256"], "preset_patches": runtime["deepclub"]["presetPatches"],
    }
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
