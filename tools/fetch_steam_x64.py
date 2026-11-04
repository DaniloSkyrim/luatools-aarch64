#!/usr/bin/env python3
"""Fetch the current Steam x86-64 client module from Valve's public CDN.

Reads the steamrt64 client manifest, selects the bins_steamrt_steamrt64 part,
verifies its SHA-256, and extracts steamrt64/steamclient.so. Used by CI to
verify that SLSsteam's signatures still match the live client before a release.

Usage:
  fetch_steam_x64.py <output-dir> [--dry-run]
"""
import hashlib
import os
import re
import sys
import urllib.request
import zipfile

CDN = "https://client-update.fastly.steamstatic.com"
MANIFEST = "steam_client_steamdeck_publicbeta_steamrt64"
PART = "bins_steamrt_steamrt64"


def fetch(url, dest):
    print(f"  GET {url}")
    with urllib.request.urlopen(url, timeout=120) as response, open(dest, "wb") as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    outdir = sys.argv[1]
    dry = "--dry-run" in sys.argv[2:]
    os.makedirs(outdir, exist_ok=True)

    manifest_path = os.path.join(outdir, "manifest.txt")
    fetch(f"{CDN}/{MANIFEST}", manifest_path)
    text = open(manifest_path, encoding="utf-8", errors="replace").read()

    start = text.find(f'"{PART}"')
    if start < 0:
        raise SystemExit(f"{PART} not found in the manifest")
    open_brace = text.find("{", start)
    depth, end = 1, open_brace + 1
    while depth and end < len(text):
        depth += {"{": 1, "}": -1}.get(text[end], 0)
        end += 1
    block = text[open_brace:end]

    file_match = re.search(r'"file"\s+"([^"]+)"', block)
    sha_match = re.search(r'"sha2"\s+"([^"]+)"', block)
    size_match = re.search(r'"size"\s+"([0-9]+)"', block)
    if not (file_match and sha_match):
        raise SystemExit("file/sha2 missing from the bins block")

    name, want_sha = file_match.group(1), sha_match.group(1)
    print(f"{PART}: {name} ({size_match.group(1) if size_match else '?'} bytes)")
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
        member = "steamrt64/steamclient.so"
        if member not in zf.namelist():
            raise SystemExit(f"{member} not present in {name}")
        zf.extract(member, outdir)
    target = os.path.join(outdir, member)
    print(f"  extracted {target} ({os.path.getsize(target)} bytes)")
    os.remove(archive)


if __name__ == "__main__":
    main()
