#!/usr/bin/env bash
# Build SLSsteam for the DroidDeck **native aarch64** Steam client.
#
# Upstream AceSLS/SLSsteam has no aarch64 support: its Makefile hardcodes
# `-m32`, its signature table describes the i386 client and its `lib/` ships
# i386 archives. patches/slsteam-aarch64.patch carries the aarch64 port
# (ARCH switch, arm64 signature table, ARM64 SDK layouts). This script applies
# that patch, builds the four static dependencies from source for aarch64,
# links SLSsteam.so and packages the release asset.
#
# Run it on a native aarch64 host (GitHub's ubuntu-24.04-arm runner). Cross
# compilation is possible with CROSS=aarch64-linux-gnu- but the static library
# build drives cmake for libmem/keystone/LLVM and is only exercised natively.
#
# Usage: build-slsteam-arm64.sh [output-dir]
# Env:   WORK        scratch directory (default: <repo>/.build)
#        LIBS_CACHE  directory holding prebuilt lib/arm64/*.a (skips the
#                    ~25 min dependency build when all four are present)
#        SKIP_LIBS=1 fail instead of building when LIBS_CACHE is incomplete
#        PUBLISH_LIBS=1 also write slsteam-arm64-libs.zip next to the output
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
out=${1:-$repo/dist}
# Resolve before cd: a relative output path would otherwise land inside the
# cloned source tree (the script cd's into it below).
out=$(realpath -m "$out")
work=${WORK:-$repo/.build}
patch_file="$repo/patches/slsteam-aarch64.patch"

# The upstream tip the port was validated against. A move means the source (and
# possibly the signatures) changed; fail loudly instead of publishing an
# unverified binary.
EXPECTED=${SLS_COMMIT:-7f59509e51bfdb9f385300bdc85269f84618bf99}

need_libs=(liblibmem.a libluajit.a libprotobuf.a libyaml-cpp.a)

host_arch=$(uname -m)
mkdir -p "$out"
mkdir -p "$work"

echo "== host $host_arch"
if [ "$host_arch" != "aarch64" ] && [ "$host_arch" != "arm64" ]; then
	echo "warning: not an aarch64 host; relying on CROSS=${CROSS:-aarch64-linux-gnu-}" >&2
fi

echo "== cloning AceSLS/SLSsteam@$EXPECTED"
rm -rf "$work/src"
# -c core.autocrlf=false: Git-for-Windows defaults to CRLF working trees, which
# breaks the LF-only patch and the embed-*.sh helpers downstream.
git -c core.autocrlf=false init -q "$work/src"
git -C "$work/src" remote add origin https://github.com/AceSLS/SLSsteam.git
git -C "$work/src" fetch --depth 1 origin "$EXPECTED"
git -c core.autocrlf=false -C "$work/src" checkout -q FETCH_HEAD
actual=$(git -C "$work/src" rev-parse HEAD)
if [ "${SLS_ALLOW_MOVE:-0}" != 1 ] && [ "$actual" != "$EXPECTED" ]; then
	echo "upstream moved: HEAD $actual, validated $EXPECTED" >&2
	echo "re-run with SLS_ALLOW_MOVE=1 after re-checking the signatures" >&2
	exit 1
fi
echo "   HEAD $actual"

echo "== applying patches/slsteam-aarch64.patch"
# core.autocrlf=true (the Git-for-Windows default) would rewrite the working
# tree to CRLF before the patch applies and fail every hunk; pin the setting
# for this checkout only.
git -c core.autocrlf=false -C "$work/src" apply --whitespace=nowarn "$patch_file"

# Guard against a patch that applied but left the broken signature behind: the
# aarch64 client moved the tail of CUser::UpdateAppOwnershipTicket, so the last
# six bytes have to be wildcards.
grep -q 'F7 03 03 2A ? ? ? ? ? ?' "$work/src/src/patterns.cpp" || {
	echo "src/patterns.cpp lost the UpdateAppOwnershipTicket wildcard fix" >&2
	exit 1
}

cd "$work/src"

# The port's Makefile defaults to aarch64 on an aarch64 host. Be explicit so a
# cross build cannot silently fall back to the i386 table.
make_args=(ARCH=aarch64)
if [ "$host_arch" != "aarch64" ] && [ "$host_arch" != "arm64" ]; then
	make_args+=("CXX=${CROSS:-aarch64-linux-gnu-}g++")
	# A native pkg-config finds the host's x86-64 .pc files; point it at the
	# aarch64 triplet when the cross toolchain installed one.
	triple=${CROSS:-aarch64-linux-gnu-}
	triple=${triple%-}
	if [ -d "/usr/lib/$triple/pkgconfig" ]; then
		export PKG_CONFIG_LIBDIR="/usr/lib/$triple/pkgconfig:/usr/share/pkgconfig"
	fi
fi

have_libs=0
if [ -n "${LIBS_CACHE:-}" ]; then
	missing=0
	for lib in "${need_libs[@]}"; do
		[ -s "$LIBS_CACHE/$lib" ] || missing=1
	done
	if [ "$missing" = 0 ]; then
		echo "== copying the prebuilt aarch64 archives from $LIBS_CACHE"
		mkdir -p lib/arm64
		cp "$LIBS_CACHE"/*.a lib/arm64/
		have_libs=1
	else
		echo "== $LIBS_CACHE is incomplete; the dependencies will be built"
	fi
fi

if [ "$have_libs" = 1 ]; then
	:
elif [ "${SKIP_LIBS:-0}" = 1 ]; then
	echo "SKIP_LIBS=1 but no usable LIBS_CACHE was given" >&2
	exit 1
else
	echo "== building the four static dependencies for aarch64"
	echo "   libmem 5.1.5 (+capstone+keystone+LLVM), yaml-cpp 0.8.0, protobuf 3.15.3, LuaJIT 2.1"
	bash tools/build-libs-arm64.sh
fi

echo "== verifying the static archives are aarch64"
python3 - <<'PY'
import glob, struct, sys

EM_ARM = 0xB7
bad = False
paths = sorted(glob.glob("lib/arm64/*.a"))
if not paths:
    sys.exit("lib/arm64 is empty")
for path in paths:
    data = open(path, "rb").read()
    if data[:8] != b"!<arch>\n":
        print(f"  {path}: not an ar archive", file=sys.stderr)
        bad = True
        continue
    off, machines, members = 8, set(), 0
    while off + 60 <= len(data):
        try:
            size = int(data[off + 48:off + 58].decode("latin-1").strip())
        except ValueError:
            break
        body = data[off + 60:off + 60 + size]
        off += 60 + size + (size & 1)
        if body[:4] == b"\x7fELF":
            members += 1
            machines.add(struct.unpack_from("<H", body, 18)[0])
    if machines != {EM_ARM}:
        print(f"  {path}: ELF machines {sorted(hex(m) for m in machines)} (want aarch64)",
              file=sys.stderr)
        bad = True
    else:
        print(f"  {path}: {members} aarch64 objects")
sys.exit(1 if bad else 0)
PY

echo "== building SLSsteam.so"
make -j"$(nproc)" "${make_args[@]}" audit-libs

[ -f bin/SLSsteam.so ] || { echo "build did not produce bin/SLSsteam.so" >&2; exit 1; }

echo "== verifying the artifact"
python3 - <<'PY'
import struct, sys
d = open("bin/SLSsteam.so", "rb").read()
if d[:4] != b"\x7fELF":
    sys.exit("bin/SLSsteam.so is not ELF")
cls, machine = d[4], struct.unpack_from("<H", d, 18)[0]
etype = struct.unpack_from("<H", d, 16)[0]
print(f"   class={cls} machine={hex(machine)} type={hex(etype)} size={len(d)}")
if cls != 2 or machine != 0xB7 or etype != 3:
    sys.exit("bin/SLSsteam.so is not an ELF64 aarch64 shared object")
# The arm64 signature table has to be the one compiled in.
if b"CUser::UpdateAppOwnershipTicket" not in d:
    sys.exit("the arm64 signature table is missing from the binary")
PY

# library-inject.so is a deliberate empty placeholder upstream (the la_objsearch
# helper is disabled). Only carry it when it is a real ELF.
have_inject=0
if [ -s bin/library-inject.so ] && \
	[ "$(head -c 4 bin/library-inject.so | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
	have_inject=1
fi

# The release archive is flat: the installer looks for SLSsteam.so anywhere in
# the extracted tree, so there is no wrapper directory.
dest="$out/slsteam-arm64"
rm -rf "$dest"
mkdir -p "$dest"
cp bin/SLSsteam.so "$dest/SLSsteam.so"
[ "$have_inject" = 1 ] && cp bin/library-inject.so "$dest/library-inject.so"
cp res/config.yaml "$dest/config.yaml"
cp res/version.txt "$dest/version.txt"
cp docs/LICENSE/SLSsteam "$dest/LICENSE"

echo "== wrote $dest"
find "$dest" -maxdepth 1 -type f -printf '   %10s  %f\n' | sort -k2

rm -f "$out/slsteam-arm64.zip"
(cd "$dest" && zip -q -r -9 "$out/slsteam-arm64.zip" .)
echo "== $out/slsteam-arm64.zip"
ls -l "$out/slsteam-arm64.zip"

# The static archives are what makes a rebuild reproducible; publish them as
# their own asset so a later run can skip the ~25 min libmem/keystone/LLVM
# compile.
if [ "${PUBLISH_LIBS:-0}" = 1 ]; then
	stage="$work/libs-stage"
	rm -rf "$stage"
	mkdir -p "$stage/lib/arm64"
	cp lib/arm64/*.a "$stage/lib/arm64/"
	rm -f "$out/slsteam-arm64-libs.zip"
	(cd "$stage" && zip -q -r -6 "$out/slsteam-arm64-libs.zip" lib)
	echo "== $out/slsteam-arm64-libs.zip"
	ls -l "$out/slsteam-arm64-libs.zip"
fi
