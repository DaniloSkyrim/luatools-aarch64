#!/usr/bin/env bash
# Offline unit tests for the installer's file-installation and launcher-patch
# logic. Runs on any POSIX shell with bash, zip/unzip, python3 and file(1):
# it does not download anything and does not touch a real DroidDeck install.
#
#   bash tests/test-install.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # check <description> <command...>
	local what=$1; shift
	if "$@"; then printf 'ok   %s\n' "$what"; else printf 'FAIL %s\n' "$what"; fail=1; fi
}

# A real ELF64 x86-64 stand-in for SLSsteam.so.
candidate=""
for c in "$root/.dd_research/slsrel/tools/schema-grabber/bin/Release/net9.0/linux-x64/publish/schema-grabber" \
         "$HOME/AppData/Local/Temp/lt-inv/slsrel/tools/schema-grabber/bin/Release/net9.0/linux-x64/publish/schema-grabber"; do
	[ -f "$c" ] && candidate=$c && break
done
if [ -z "$candidate" ]; then
	candidate=$(find "$root/.dd_research" "$TEMP" -maxdepth 8 -type f -name schema-grabber 2>/dev/null | head -n1)
fi
if [ -z "$candidate" ]; then
	echo "SKIP: no ELF64 x86-64 sample available (extract a DroidDeck component first)"
	exit 0
fi

# ---- fixture: release zip --------------------------------------------------
mkdir -p "$tmp/pkg/slsteam-x86_64/bin" "$tmp/pkg/slsteam-x86_64/res"
cp "$candidate" "$tmp/pkg/slsteam-x86_64/bin/SLSsteam.so"
: > "$tmp/pkg/slsteam-x86_64/bin/library-inject.so"
printf 'test: true\n' > "$tmp/pkg/slsteam-x86_64/res/config.yaml"
# install_slsteam_from_zip walks the extracted tree; the zip path is unused.
: > "$tmp/slsteam-x86_64.zip"

# Git Bash may expose a broken python3 alias while `python` works.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexec python "$@"\n' > "$tmp/bin/python3"
chmod +x "$tmp/bin/python3"
PATH="$tmp/bin:$PATH"
export PATH

# ---- load installer functions only ----------------------------------------
export LUATOOLS_LIB_ONLY=1
# shellcheck disable=SC1090
. "$root/install.sh"

# The script sets these at load time; point them at the fixture.
SLS_DIR="$tmp/x64/share/SLSsteam"
LUMEN_DIR="$tmp/x64/share/Lumen"
X64_HOME="$tmp/x64"
STEAM_X64="$X64_HOME/.local/share/Steam"
SHARE="$X64_HOME/.local/share"
DROIDDECK_X64="$tmp/droiddeck-steam-x64"

check "SLSsteam installs from the release zip" \
	install_slsteam_from_zip "$tmp/slsteam-x86_64.zip" "$tmp/pkg"
check "SLSsteam.so present" test -s "$SLS_DIR/SLSsteam.so"
check "empty library-inject.so is not installed" test ! -e "$SLS_DIR/library-inject.so"
check "config.yaml copied" test -f "$SLS_DIR/res/config.yaml"

# ---- launcher patch --------------------------------------------------------
cp "$root/.dd_research/tools_linuxfs_overlay_usr_local_bin_droiddeck-steam-x64" "$DROIDDECK_X64" 2>/dev/null || \
	cp "$TEMP/lt-inv/x/droiddeck-steam-x64" "$DROIDDECK_X64" 2>/dev/null
if [ -f "$DROIDDECK_X64" ]; then
	check "launcher patch applies" patch_droiddeck
	check "launcher still parses" bash -n "$DROIDDECK_X64"
	check "marker present once" test "$(grep -c '>>> SLSSTEAM-X64-INJECT' "$DROIDDECK_X64")" -eq 1
	check "patch is idempotent" patch_droiddeck
	check "marker still once" test "$(grep -c '>>> SLSSTEAM-X64-INJECT' "$DROIDDECK_X64")" -eq 1
	check "unpatch restores the backup" unpatch_droiddeck
	check "marker gone" test "$(grep -c '>>> SLSSTEAM-X64-INJECT' "$DROIDDECK_X64")" -eq 0
else
	echo "SKIP: real droiddeck-steam-x64 not available"
fi

exit "$fail"
