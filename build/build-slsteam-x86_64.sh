#!/usr/bin/env bash
# Build SLSsteam for the x86-64 Steam client used by DroidDeck's x86-64 mode.
#
# The upstream dev-X86_64 branch already carries the 64-bit layouts and all
# four static dependencies as ELF64 x86-64 archives. All 17 compiled-in
# signatures match the current steamrt64/steamclient.so uniquely, so this is a
# plain upstream build, not a patched source tree.
#
# Usage: build-slsteam-x86_64.sh [output-dir]
# Env:   SLS_REF   branch or tag to build (default: dev-X86_64)
#        WORK      scratch directory (default: <repo>/.build)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../dist}
# Resolve before cd: a relative output path would otherwise land inside the
# cloned source tree (the script cd's into it below).
out=$(realpath -m "$out")
work=${WORK:-$here/../.build}
ref=${SLS_REF:-dev-X86_64}

mkdir -p "$out"
rm -rf "$work"
mkdir -p "$work"

echo "== cloning AceSLS/SLSsteam@$ref"
git clone --depth 1 --branch "$ref" https://github.com/AceSLS/SLSsteam "$work/src"

cd "$work/src"

# The branch tip this port was validated against. A move means the source (and
# possibly the signatures) changed; fail loudly instead of publishing an
# unverified binary. SLS_ALLOW_MOVE=1 rebuilds from the new tip deliberately.
EXPECTED=${SLS_COMMIT:-2751bbd932d668a31903714f4903ff799b591d5b}
actual=$(git rev-parse HEAD)
if [ "${SLS_ALLOW_MOVE:-0}" != 1 ] && [ "$actual" != "$EXPECTED" ]; then
	echo "dev-X86_64 moved: HEAD $actual, validated $EXPECTED" >&2
	echo "re-run with SLS_ALLOW_MOVE=1 after re-checking the signatures" >&2
	exit 1
fi
echo "   HEAD $actual"

echo "== building (this produces bin/SLSsteam.so and bin/library-inject.so)"
make -j"$(nproc)" audit-libs

[ -f bin/SLSsteam.so ] || { echo "build did not produce bin/SLSsteam.so" >&2; exit 1; }
if ! file -b bin/SLSsteam.so | grep -q 'ELF 64-bit'; then
	echo "bin/SLSsteam.so is not ELF64: $(file -b bin/SLSsteam.so)" >&2
	exit 1
fi
# dev-X86_64 deliberately ships library-inject.so as an empty placeholder
# (the la_objsearch helper is disabled there). Only carry it when it is a
# real ELF, otherwise LD_AUDIT must list SLSsteam.so alone.
have_inject=0
if [ -s bin/library-inject.so ] && file -b bin/library-inject.so | grep -q 'ELF 64-bit'; then
	have_inject=1
fi

dest="$out/slsteam-x86_64"
rm -rf "$dest"
mkdir -p "$dest/bin" "$dest/res" "$dest/docs"
cp bin/SLSsteam.so "$dest/bin/"
[ "$have_inject" = 1 ] && cp bin/library-inject.so "$dest/bin/"
cp setup.sh "$dest/"
cp res/config.yaml "$dest/res/"
[ -d docs/LICENSE ] && cp -r docs/LICENSE "$dest/docs/LICENSE"

echo "== wrote $dest"
find "$dest" -maxdepth 3 -type f -printf '   %s  %p\n' | sort -k2
