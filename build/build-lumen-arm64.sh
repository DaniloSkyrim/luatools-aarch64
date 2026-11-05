#!/usr/bin/env bash
# Build Lumen for the DroidDeck **native aarch64** Steam client.
#
# Upstream swwayps/lumen builds a portable x86-64 binary (glibc 2.34 floor) and
# its lua/ tree assumes the client process is called `steam`. On the DroidDeck
# the client is the native aarch64 build in steamrtarm64/, exec'd as `steam.real`
# behind the SLSsteam wrapper, so the liveness check, the SLSsteam detection and
# the Restart Steam helper all have to recognise that name.
#
# patches/lumen-aarch64.patch carries those edits. This script builds the binary
# from source and packages the release asset (lumen + lua/).
#
# Run it on a native aarch64 host. The binary links libcurl and liblua5.4
# statically (LuaJIT-style: no Lua runtime dependency) but glibc dynamically, so
# build it on the oldest glibc you need to support; the DroidDeck image ships
# 2.43, so an ubuntu-24.04-arm (2.39) build is fine.
#
# Usage: build-lumen-aarch64.sh [output-dir]
# Env:   WORK            scratch directory (default: <repo>/.build)
#        LUMEN_COMMIT    upstream commit to build (default: the validated one)
#        PATCH_LUA=1     apply patches/lumen-aarch64.patch (default: 1)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
out=${1:-$repo/dist}
out=$(realpath -m "$out")
work=${WORK:-$repo/.build}
patch_file="$repo/patches/lumen-aarch64.patch"

# The upstream tip the lua/ patch was validated against.
EXPECTED=${LUMEN_COMMIT:-52475c3ec0bbe2bf0ccdd209d86a40d99a9881fa}

mkdir -p "$out"

echo "== cloning swwayps/lumen@$EXPECTED"
if [ -d "$work/lumen/.git" ]; then
	git -C "$work/lumen" fetch --depth 1 origin "$EXPECTED"
	git -C "$work/lumen" checkout -q FETCH_HEAD
else
	mkdir -p "$work"
	git init -q "$work/lumen"
	git -C "$work/lumen" remote add origin https://github.com/swwayps/lumen.git
	git -C "$work/lumen" fetch --depth 1 origin "$EXPECTED"
	git -C "$work/lumen" checkout -q FETCH_HEAD
fi
echo "   HEAD $(git -C "$work/lumen" rev-parse HEAD)"

cd "$work/lumen"

echo "== building bin/lumen"
make clean >/dev/null 2>&1 || true
make -j"$(nproc)"

[ -x bin/lumen ] || { echo "build did not produce bin/lumen" >&2; exit 1; }

echo "== verifying the artifact"
python3 - <<'PY'
import struct, sys
d = open("bin/lumen", "rb").read()
if d[:4] != b"\x7fELF":
    sys.exit("bin/lumen is not ELF")
cls, machine = d[4], struct.unpack_from("<H", d, 18)[0]
etype, entry = struct.unpack_from("<H", d, 16)[0], struct.unpack_from("<Q", d, 24)[0]
print(f"   class={cls} machine={hex(machine)} type={hex(etype)} entry={hex(entry)} size={len(d)}")
if cls != 2 or machine != 0xB7:
    sys.exit("bin/lumen is not an ELF64 aarch64 binary")
# Ubuntu builds PIE by default, so an executable is ET_EXEC (2) or ET_DYN (3)
# with a non-zero entry point; a shared object has no entry point.
if etype not in (2, 3) or entry == 0:
    sys.exit(f"bin/lumen is not an executable (type={etype} entry={entry})")
PY

if [ "${PATCH_LUA:-1}" = 1 ]; then
	echo "== applying patches/lumen-aarch64.patch to lua/"
	git apply --check --whitespace=nowarn "$patch_file"
	git apply --whitespace=nowarn "$patch_file"
fi

# The installer recognises the patched helpers by these markers.
grep -q 'steam.real' lua/loop.lua || {
	echo "lua/loop.lua does not know steam.real" >&2
	exit 1
}
grep -q 'STEAM_COMMS' lua/slscheck.lua || {
	echo "lua/slscheck.lua does not list steam.real" >&2
	exit 1
}
# pgrep -x in that script uses a regex, so the asset carries 'steam\.real'.
grep -qF 'steam.real' lua/restart_steam.sh || grep -qF 'steam\.real' lua/restart_steam.sh || {
	echo "lua/restart_steam.sh does not match steam.real" >&2
	exit 1
}

dest="$out/lumen-arm64"
rm -rf "$dest"
mkdir -p "$dest"
cp bin/lumen "$dest/lumen"
cp -r lua "$dest/lua"

echo "== wrote $dest"
find "$dest" -maxdepth 2 -type f -printf '   %10s  %p\n' | sort -k2 | head -n 12

rm -f "$out/lumen-arm64.zip"
(cd "$dest" && zip -qr9 "$out/lumen-arm64.zip" .)
echo "== $out/lumen-arm64.zip"
ls -l "$out/lumen-arm64.zip"
