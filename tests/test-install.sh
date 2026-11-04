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
check "launcher shims install" install_slsteam_shims
check "restart shim parses" sh -n "$SLS_DIR/path/steam"
check "restart shim restores the outer home" \
	grep -q 'HOME=$(dirname "$x64")' "$SLS_DIR/path/steam"

# ---- launcher patch --------------------------------------------------------
cp "$root/.dd_research/tools_linuxfs_overlay_usr_local_bin_droiddeck-steam-x64" "$DROIDDECK_X64" 2>/dev/null || \
	cp "$TEMP/lt-inv/x/droiddeck-steam-x64" "$DROIDDECK_X64" 2>/dev/null
if [ -f "$DROIDDECK_X64" ]; then
	check "launcher patch applies" patch_droiddeck
	check "launcher still parses" bash -n "$DROIDDECK_X64"
	check "marker present once" test "$(grep -c '>>> SLSSTEAM-X64-INJECT' "$DROIDDECK_X64")" -eq 1
	# The block must resolve the share dir inside DroidDeck's x86-64 home (not
	# the desktop session's $HOME/.local/share) and must not export LD_AUDIT to
	# the aarch64 loader.
	check "patch uses DroidDeck's x86-64 share dir" \
		grep -q 'SLS_SHARE="${X64_HOME:-$HOME/.droiddeck-x64}/.local/share"' "$DROIDDECK_X64"
	check "patch strips LD_AUDIT from the host env" \
		grep -q 'unset LD_AUDIT' "$DROIDDECK_X64"
	check "patch enables CEF debugging in the guest" \
		grep -q 'touch "$STEAM_X64/.cef-enable-remote-debugging"' "$DROIDDECK_X64"
	check "patch is idempotent" patch_droiddeck
	check "marker still once" test "$(grep -c '>>> SLSSTEAM-X64-INJECT' "$DROIDDECK_X64")" -eq 1
	check "unpatch restores the backup" unpatch_droiddeck
	check "marker gone" test "$(grep -c '>>> SLSSTEAM-X64-INJECT' "$DROIDDECK_X64")" -eq 0
else
	echo "SKIP: real droiddeck-steam-x64 not available"
fi

# ---- Lumen patches ---------------------------------------------------------
mkdir -p "$LUMEN_DIR/lua"
cat > "$LUMEN_DIR/lua/proc.lua" <<'LUA'
local proc = {}

function proc.is_alive(comm, root)
  local root = root or "/proc"
  for entry in pairs({}) do
    local name = "steam"
    if name == comm then found = true; break end
  end
  return found
end

function proc.lib_mapped(comm, needle, root)
  for entry in pairs({}) do
    local name = "steam"
    if name == comm then
      found = true
    end
  end
  return found
end

return proc
LUA
cat > "$LUMEN_DIR/lua/about.lua" <<'LUA'
about.INSTALL_URL =
  "https://raw.githubusercontent.com/swwayps/luatools-moon/main/install.sh"
LUA
check "proc.lua patch applies" patch_lumen_proc "$LUMEN_DIR/lua/proc.lua"
check "proc.lua matches via cmdline" grep -q 'SLSSTEAM-FEX-MATCH' "$LUMEN_DIR/lua/proc.lua"
check "both proc.lua call sites patched" \
	test "$(grep -c 'sls_match(comm, name, root, entry)' "$LUMEN_DIR/lua/proc.lua")" -eq 2
check "proc.lua patch is idempotent" patch_lumen_proc "$LUMEN_DIR/lua/proc.lua"
check "about.lua patch applies" patch_lumen_about "$LUMEN_DIR/lua/about.lua"
check "about.lua points at this repo" \
	grep -q "raw.githubusercontent.com/DaniloSkyrim/luatools-aarch64/main/install.sh" "$LUMEN_DIR/lua/about.lua"
check "about.lua patch is idempotent" patch_lumen_about "$LUMEN_DIR/lua/about.lua"

cat > "$LUMEN_DIR/lua/restart_steam.sh" <<'SH'
#!/usr/bin/env bash
set -u
CHECK_ONLY="${1:-}"
if pgrep -x steam >/dev/null 2>&1; then
  pkill -TERM -x steam >/dev/null 2>&1 || true
fi
if ! pgrep -x steam >/dev/null 2>&1; then
  pkill -KILL -x steam >/dev/null 2>&1 || true
fi
SH
check "restart helper patch applies" patch_lumen_restart "$LUMEN_DIR/lua/restart_steam.sh"
check "restart helper parses" bash -n "$LUMEN_DIR/lua/restart_steam.sh"
check "restart helper matches the FEX guest" \
	grep -qF "pgrep -f 'steamrt64/steam( |\$)'" "$LUMEN_DIR/lua/restart_steam.sh"
check "restart helper no longer probes comm only" \
	test "$(grep -c 'pgrep -x steam' "$LUMEN_DIR/lua/restart_steam.sh")" -eq 1
check "restart helper patch is idempotent" patch_lumen_restart "$LUMEN_DIR/lua/restart_steam.sh"

# ---- plugin reinstall keeps user data -------------------------------------
mkdir -p "$tmp/plug-src/public" "$tmp/plug-src/backend"
printf '{"name":"LuaTools"}\n' > "$tmp/plug-src/plugin.json"
: > "$tmp/plug-src/public/luatools.js"
: > "$tmp/plug-src/backend/main.lua"
python - "$tmp/plug-src" "$tmp/luatools-linux.zip" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as zf:
    for base, _, files in os.walk(src):
        for name in files:
            full = os.path.join(base, name)
            zf.write(full, os.path.relpath(full, src))
PY
mkdir -p "$LUMEN_DIR/luatools/backend/data"
printf '{"language":"pt-BR"}\n' > "$LUMEN_DIR/luatools/backend/data/settings.json"
TMP="$tmp/plugin-tmp"; mkdir -p "$TMP"
PLUGIN_ZIP_URL="file://$tmp/luatools-linux.zip"
install_sevenzip() { :; }   # no network in this test
fetch() { cp "${1#file://}" "$2"; }   # local archive, no curl/file:// dependency
check "plugin reinstalls from the archive" install_plugin
check "plugin files installed" test -f "$LUMEN_DIR/luatools/plugin.json"
check "user settings survive a reinstall" \
	grep -q 'pt-BR' "$LUMEN_DIR/luatools/backend/data/settings.json"

# ---- CloudRedirect: x86-64 CLI gets a FEX wrapper -------------------------
mkdir -p "$tmp/cr-src/cloudredirect-x86_64"
cp "$candidate" "$tmp/cr-src/cloudredirect-x86_64/cloud_redirect.so"
cp "$candidate" "$tmp/cr-src/cloudredirect-x86_64/cloud_redirect_cli"
python - "$tmp/cr-src" "$tmp/cr.zip" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as zf:
    for base, _, files in os.walk(src):
        for name in files:
            full = os.path.join(base, name)
            zf.write(full, os.path.relpath(full, src))
PY
CLOUDREDIRECT_URL="file://$tmp/cr.zip"
TMP="$tmp/cr-tmp"; mkdir -p "$TMP"
check "CloudRedirect installs" install_cloudredirect
check "CloudRedirect hook present" test -f "$SHARE/CloudRedirect/cloud_redirect.so"
check "CloudRedirect CLI wrapper is a script" \
	grep -q 'FEX_ROOTFS' "$SHARE/CloudRedirect/cloud_redirect_cli"
check "CloudRedirect CLI wrapper parses" sh -n "$SHARE/CloudRedirect/cloud_redirect_cli"
check "CloudRedirect CLI binary kept" test -f "$SHARE/CloudRedirect/cloud_redirect_cli.bin"

exit "$fail"
