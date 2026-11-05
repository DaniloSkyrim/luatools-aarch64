#!/usr/bin/env python3
"""Fetch the current Steam aarch64 client module from Valve's public CDN.

The DroidDeck native client is the `linuxarm64` build of the Steam client (the
same one Valve ships for SteamOS ARM64 and Apple-silicon Linux). Its files live
in the `steamrtarm64/` directory of the client root, so the part that carries
steamclient.so is `bins_linuxarm64_linuxarm64`.

This script reads the manifest, verifies the SHA-256 of the downloaded part and
extracts `steamrtarm64/steamclient.so`. CI uses it to prove that SLSsteam's
arm64 signatures still match the live client before publishing a release.

Usage:
  fetch_steam_aarch64.py <output-dir> [--channel publicbeta|stable] [--dry-run]
"""
import hashlib
import os
import re
import sys
import urllib.request
import zipfile

CDN = "https://client-update.fastly.steamstatic.com"
PART = "bins_linuxarm64_linuxarm64"
MEMBER = "steamrtarm64/steamclient.so"


def fetch(url, dest):
    print(f"  GET {url}")
    with urllib.request.urlopen(url, timeout=120) as response, open(dest, "wb") as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def part_block(text, part):
    """Return the manifest block for `part` (the manifest is a loose magma file,
    not JSON, so braces are matched by hand)."""
    start = text.find(f'"{part}"')
    if start < 0:
        raise SystemExit(f"{part} not found in the manifest")
    open_brace = text.find("{", start)
    depth, end = 1, open_brace + 1
    while depth and end < len(text):
        depth += {"{": 1, "}": -1}.get(text[end], 0)
        end += 1
    return text[open_brace:end]


def field(block, name):
    match = re.search(rf'"{name}"\s+"([^"]+)"', block)
    return match.group(1) if match else None


def main():
    argv = sys.argv[1:]
    channel = "publicbeta"
    dry = "--dry-run" in argv
    if "--channel" in argv:
        channel = argv[argv.index("--channel") + 1]
    args = [a for a in argv if a != "--dry-run" and a != "--channel"
            and a != channel]
    if not args:
        raise SystemExit(__doc__)
    outdir = args[0]
    os.makedirs(outdir, exist_ok=True)

    manifest = f"steam_client_steamdeck_{channel}_linuxarm64"
    manifest_path = os.path.join(outdir, "manifest.txt")
    fetch(f"{CDN}/{manifest}", manifest_path)
    text = open(manifest_path, encoding="utf-8", errors="replace").read()
    print(f"{manifest}: version {field(text, 'version')}")

    block = part_block(text, PART)
    name, want_sha = field(block, "file"), field(block, "sha2")
    if not (name and want_sha):
        raise SystemExit(f"file/sha2 missing from the {PART} block")
    print(f"{PART}: {name} ({field(block, 'size')} bytes)")
    if dry:
        print(f"  sha256 {want_sha}")
        return

    archive = os.path.join(outdir, name)
    fetch(f"{CDN}/{name}", archive)
    digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
    if digest != want_sha:
        raise SystemExit(f"sha256 mismatch: got {digest}, want {want_sha}")
    print(f"  sha256 ok: {digest}")

    with zipfile.ZipFile(archive) as zf:
        if MEMBER not in zf.namelist():
            raise SystemExit(f"{MEMBER} not present in {name}")
        zf.extract(MEMBER, outdir)
    target = os.path.join(outdir, MEMBER)
    print(f"  extracted {target} ({os.path.getsize(target)} bytes)")
    os.remove(archive)


if __name__ == "__main__":
    main()
