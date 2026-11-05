#!/usr/bin/env bash
# Offline tests for the aarch64 installer: file installation, the SLSsteam
# launcher wrapper, the droiddeck-steam-install hook and the uninstall path.
#
# It never touches a real DroidDeck install and never downloads anything: every
# fixture is a synthetic ELF plus a local zip built by tests/mkzip.py.
#
#   bash tests/test-install.sh
#
# Runs on Git Bash as well as on Linux: no pgrep/pkill/setsid/zip needed.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
skipped=0

check() { # check <description> <command...>
	local what=$1; shift
	if "$@"; then printf 'ok   %s\n' "$what"; else printf 'FAIL %s\n' "$what"; fail=1; fi
}

check_not() { # check_not <description> <command...>
	local what=$1; shift
	if "$@"; then printf 'FAIL %s\n' "$what"; fail=1; else printf 'ok   %s\n' "$what"; fi
}

skip() { printf 'SKIP %s\n' "$*"; skipped=$((skipped + 1)); }

py=""
for c in python3 python; do
	p=$(command -v "$c" 2>/dev/null) || continue
	# Git Bash on Windows resolves python3 to the Microsoft Store stub, which
	# prints a "Python was not found" banner and exits 9009. Probe it.
	[ -n "$p" ] || continue
	if "$p" -c 'import sys' >/dev/null 2>&1; then py=$p; break; fi
done
if [ -z "$py" ]; then
	echo "SKIP: python is required to build the fixtures"
	exit 0
fi
mkelf() { "$py" "$root/tests/mkelf.py" "$@"; }
mkzip() { "$py" "$root/tests/mkzip.py" "$@"; }

# ---- fixtures --------------------------------------------------------------
# A synthetic aarch64 ELF64 header is all the installer inspects.
mkdir -p "$tmp/elf"
mkelf "$tmp/elf/aarch64.so" 0xB7 3
mkelf "$tmp/elf/aarch64.exe" 0xB7 2
mkelf "$tmp/elf/x86_64.so" 0x3E 3
mkelf "$tmp/elf/i386.so" 0x03 3
printf 'not an elf\n' > "$tmp/elf/text"

# Release archive: flat, like the one the CI publishes.
mkdir -p "$tmp/pkg/slsteam/res"
cp "$tmp/elf/aarch64.so" "$tmp/pkg/slsteam/SLSsteam.so"
: > "$tmp/pkg/slsteam/library-inject.so"   # deliberate upstream placeholder
printf 'DisableFamilyShareLock: yes\n' > "$tmp/pkg/slsteam/config.yaml"
printf '20261014151919\n' > "$tmp/pkg/slsteam/version.txt"
printf 'license\n' > "$tmp/pkg/slsteam/LICENSE"
mkzip "$tmp/pkg/slsteam" "$tmp/slsteam-arm64.zip"

# Lumen archive: binary plus the patched lua tree.
mkdir -p "$tmp/pkg/lumen/lua"
cp "$tmp/elf/aarch64.exe" "$tmp/pkg/lumen/lumen"
cat > "$tmp/pkg/lumen/lua/loop.lua" <<'LUA'
local steam_alive = proc.is_alive("steam") or proc.is_alive("steam.real")
LUA
cat > "$tmp/pkg/lumen/lua/slscheck.lua" <<'LUA'
slscheck.STEAM_COMMS = { "steam", "steam.real" }
LUA
cat > "$tmp/pkg/lumen/lua/restart_steam.sh" <<'SH'
#!/usr/bin/env bash
if pgrep -x '(steam|steam\.real)' >/dev/null 2>&1; then
  pkill -TERM -x '(steam|steam\.real)' >/dev/null 2>&1 || true
fi
SH
mkzip "$tmp/pkg/lumen" "$tmp/lumen-arm64.zip"

# A vanilla (unpatched) Lumen tree exercises the installer's fallback edits.
mkdir -p "$tmp/vanilla/lua"
cat > "$tmp/vanilla/lua/about.lua" <<'LUA'
-- The public one-liner the Update All button runs in a terminal. Raw-branch URL
-- (not a release asset) so installer fixes go live without a rebuild.
about.INSTALL_URL =
  "https://raw.githubusercontent.com/swwayps/luatools-moon/main/install.sh"

-- Where the installer stamps the installed release tags.
function about.versions_path()
  local home = os.getenv("HOME") or ""
  return home .. "/.local/share/Lumen/versions.json"
end
LUA

# Steam client fixture: the native launcher, plus the droiddeck scripts.
mkdir -p "$tmp/home/.local/share/Steam/steamrtarm64"
cp "$tmp/elf/aarch64.exe" "$tmp/home/.local/share/Steam/steamrtarm64/steam"
chmod 0755 "$tmp/home/.local/share/Steam/steamrtarm64/steam"
printf 'steamclient\n' > "$tmp/home/.local/share/Steam/steamrtarm64/steamclient.so"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/droiddeck-steam-install" <<'SH'
#!/bin/bash
set -eu
steam_root="$HOME/.local/share/Steam"
mkdir -p "$steam_root/steamrtarm64"
# (test fixture: the real script downloads the client here)
chmod +x "$steam_root/steamrtarm64/steam" 2>/dev/null || true
echo "droiddeck-steam-install done"
SH
chmod +x "$tmp/bin/droiddeck-steam-install"
cat > "$tmp/bin/droiddeck-steam-x64" <<'SH'
#!/bin/bash
echo "droiddeck-steam-x64"
SH
chmod +x "$tmp/bin/droiddeck-steam-x64"

# ---- load the installer without running main -------------------------------
export HOME="$tmp/home"
export TMP="$tmp/work"
export LUATOOLS_LIB_ONLY=1
export DROIDDECK_STEAM_INSTALL="$tmp/bin/droiddeck-steam-install"
export DROIDDECK_STEAM_X64="$tmp/bin/droiddeck-steam-x64"
mkdir -p "$TMP"
# shellcheck disable=SC1090
. "$root/install.sh"

# ---- ELF detection ---------------------------------------------------------
check "elf_arch: aarch64 shared object" test "$(elf_arch "$tmp/elf/aarch64.so")" = aarch64
check "elf_arch: x86-64" test "$(elf_arch "$tmp/elf/x86_64.so")" = x86-64
check "elf_arch: i386" test "$(elf_arch "$tmp/elf/i386.so")" = i386
check_not "elf_arch rejects a text file" elf_arch "$tmp/elf/text"
check_not "elf_arch rejects a missing file" elf_arch "$tmp/elf/nope"

# ---- SLSsteam --------------------------------------------------------------
SLS_RELEASE_URL="file://$tmp/slsteam-arm64.zip"
check "SLSsteam installs from the aarch64 asset" install_slsteam
check "SLSsteam.so installed" test -s "$SLS_DIR/SLSsteam.so"
check "SLSsteam.so is the aarch64 object" \
	test "$(elf_arch "$SLS_DIR/SLSsteam.so")" = aarch64
check "empty library-inject.so is not installed" test ! -e "$SLS_DIR/library-inject.so"
check "config.yaml shipped to res/" test -f "$SLS_DIR/res/config.yaml"
check "config seeded in XDG_CONFIG_HOME" test -f "$CONFIG_FILE"
check "restart shim parses" sh -n "$SLS_DIR/path/steam"
check "restart shim runs the aarch64 launcher" \
	grep -qF 'steamrtarm64/steam' "$SLS_DIR/path/steam"
check "desktop coverage shim is a successful no-op" \
	grep -qF 'exit 0' "$SLS_DIR/ensure-desktop-coverage.sh"

# A second run must not clobber settings already present.
printf 'AppIds:\n  - 440\n' > "$CONFIG_FILE"
check "SLSsteam reinstall" install_slsteam
check "existing SLSsteam settings survive a reinstall" \
	grep -q '440' "$CONFIG_FILE"

# The old x86-64 home seeds the config only when nothing exists yet.
rm -f "$CONFIG_FILE"
mkdir -p "$LEGACY_HOME/.config/SLSsteam"
printf 'AppIds:\n  - 730\n' > "$LEGACY_HOME/.config/SLSsteam/config.yaml"
check "legacy config seeds a fresh install" seed_config
check "legacy appids migrated" grep -q '730' "$CONFIG_FILE"

# ---- Lumen -----------------------------------------------------------------
LUMEN_RELEASE_URL="file://$tmp/lumen-arm64.zip"
check "Lumen installs from the aarch64 asset" install_lumen
check "lumen binary installed" test -s "$LUMEN_DIR/lumen"
check "lumen is the aarch64 executable" \
	test "$(elf_arch "$LUMEN_DIR/lumen")" = aarch64
check "lua tree installed" test -f "$LUMEN_DIR/lua/loop.lua"
check "Lumen reinstall" install_lumen
check "Lumen reinstall is idempotent" install_lumen

# Fallback edits for a vanilla tree: Update All must re-run this installer.
cp "$tmp/vanilla/lua/about.lua" "$LUMEN_DIR/lua/about.lua"
check "vanilla about.lua gets the local installer URL" patch_lumen_bundle
check "about.lua marker present" \
	grep -qF 'LUA_TOOLS-AARCH64-INSTALLER' "$LUMEN_DIR/lua/about.lua"
check "about.lua points at the Lumen-local installer" \
	grep -qF '"file://" .. (os.getenv("HOME") or "") .. "/.local/share/Lumen/install.sh"' \
	"$LUMEN_DIR/lua/about.lua"
check "about.lua keeps the rest of the file" \
	grep -qF 'function about.versions_path()' "$LUMEN_DIR/lua/about.lua"
check "about.lua edit is idempotent" patch_lumen_bundle
check "about.lua has a single marker" \
	test "$(grep -c 'LUA_TOOLS-AARCH64-INSTALLER' "$LUMEN_DIR/lua/about.lua")" -eq 1

# ---- launcher wrapper ------------------------------------------------------
check "launcher wrapper applies" install_launcher_wrapper
check "steam is the wrapper" \
	grep -qF 'SLSsteam launcher wrapper' "$STEAM_BIN"
check "steam.real is the native client" \
	test "$(elf_arch "$STEAM_REAL")" = aarch64
check "wrapper injects SLSsteam" grep -qF 'LD_AUDIT="$SLS_SO' "$STEAM_BIN"
check "wrapper strips inherited SLSsteam auditors" \
	grep -qF '*SLSsteam.so|*library-inject.so' "$STEAM_BIN"
check "wrapper adds -noverifyfiles for desktop launches" \
	grep -qF -- '-noverifyfiles' "$STEAM_BIN"
check "wrapper creates the CEF flag in the Steam root" \
	grep -qF 'touch "$here/../.cef-enable-remote-debugging"' "$STEAM_BIN"
check "wrapper creates the CEF flag in the client dir" \
	grep -qF 'touch "$here/.cef-enable-remote-debugging"' "$STEAM_BIN"
check "wrapper publishes the cef_port contract" \
	grep -qF 'cef_port' "$STEAM_BIN"
check "wrapper writes the owner pid and start ticks" \
	grep -qF 'owner %s %s' "$STEAM_BIN"
check "wrapper runs Lumen without the injection env" \
	grep -qF 'env -u LD_AUDIT -u LD_PRELOAD' "$STEAM_BIN"
check "wrapper refuses to recurse without steam.real" \
	grep -qF 'refusing to recurse' "$STEAM_BIN"
check "wrapper parses" bash -n "$STEAM_BIN"
check "apply-wrap parses" bash -n "$APPLY_WRAP"

# Re-running the installer must refresh, not replace, an existing wrapper.
check "wrapper re-apply is idempotent" install_launcher_wrapper
check "steam.real survived the re-apply" test -s "$STEAM_REAL"

# ---- run the wrapper for real ---------------------------------------------
# Git Bash has no pgrep/setsid; stub them so the wrapper's Lumen launch cannot
# block the test. The client itself is a script that records what it received.
mkdir -p "$tmp/stub" "$tmp/run"
printf '#!/bin/sh\nexit 1\n' > "$tmp/stub/pgrep"
printf '#!/bin/sh\nexec "$@"\n' > "$tmp/stub/setsid"
chmod +x "$tmp/stub/pgrep" "$tmp/stub/setsid"
cat > "$tmp/run/steam.real" <<'SH'
#!/bin/sh
{
	printf 'argv:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
	printf 'LD_AUDIT=%s\n' "${LD_AUDIT:-<unset>}"
	printf 'cef_root=%s\n' "$([ -e "$(dirname "$0")/../.cef-enable-remote-debugging" ] && echo yes || echo no)"
} > "$RECORD"
SH
chmod +x "$tmp/run/steam.real"
cp "$STEAM_BIN" "$tmp/run/steam"
check "wrapper runs the client" env PATH="$tmp/stub:$PATH" RECORD="$tmp/run/record" \
	"$tmp/run/steam" -cef-enable-debugging
check "wrapper forwards the original arguments" \
	grep -qF 'argv: [-cef-enable-debugging]' "$tmp/run/record"
check "wrapper appends -noverifyfiles" \
	grep -qF '[-noverifyfiles]' "$tmp/run/record"
check "wrapper injects SLSsteam through LD_AUDIT" \
	grep -qF "LD_AUDIT=$SLS_DIR/SLSsteam.so" "$tmp/run/record"
check "wrapper creates the CEF flag in the Steam root" \
	test -f "$tmp/.cef-enable-remote-debugging"
check "wrapper publishes cef_port" test -f "$LUMEN_DIR/cef_port"
check "cef_port starts with the DevTools port" \
	test "$(head -n1 "$LUMEN_DIR/cef_port")" = 8080

# A -shutdown must not inject, start Lumen or rewrite the contract.
rm -f "$LUMEN_DIR/cef_port" "$tmp/.cef-enable-remote-debugging"
check "wrapper handles -shutdown" env PATH="$tmp/stub:$PATH" RECORD="$tmp/run/record" \
	"$tmp/run/steam" -shutdown
check "-shutdown is passed through" grep -qF '[-shutdown]' "$tmp/run/record"
check "-shutdown does not inject SLSsteam" \
	grep -qF 'LD_AUDIT=<unset>' "$tmp/run/record"
check "-shutdown does not publish cef_port" test ! -e "$LUMEN_DIR/cef_port"

# SLS_DISABLE=1: a clean session with no injection at all.
check "wrapper honours SLS_DISABLE" env PATH="$tmp/stub:$PATH" RECORD="$tmp/run/record" \
	SLS_DISABLE=1 "$tmp/run/steam"
check "SLS_DISABLE leaves LD_AUDIT unset" \
	grep -qF 'LD_AUDIT=<unset>' "$tmp/run/record"

# An inherited auditor is stripped so SLSsteam cannot be loaded twice.
check "wrapper strips an inherited SLSsteam auditor" \
	env PATH="$tmp/stub:$PATH" RECORD="$tmp/run/record" \
	LD_AUDIT="/opt/other.so:$SLS_DIR/SLSsteam.so" "$tmp/run/steam"
check "unrelated inherited auditors survive" \
	grep -qF ':/opt/other.so' "$tmp/run/record"
check "SLSsteam is listed exactly once" \
	test "$(grep -o 'SLSsteam.so' "$tmp/run/record" | wc -l)" -eq 1
rm -rf "$tmp/.cef-enable-remote-debugging" "$tmp/run"

# A Steam client update puts Valve's ELF back at steam/ and leaves steam.real
# behind; the hook has to wrap it again.
cp "$tmp/elf/aarch64.exe" "$STEAM_BIN"
chmod 0755 "$STEAM_BIN"
check "client update simulation re-wraps the launcher" "$APPLY_WRAP"
check "steam is the wrapper again" \
	grep -qF 'SLSsteam launcher wrapper' "$STEAM_BIN"

# ---- droiddeck-steam-install hook -----------------------------------------
check "hook installed" grep -qF "$MARK_BEGIN" "$STEAM_INSTALL"
check "hook installed once" \
	test "$(grep -cF "$MARK_BEGIN" "$STEAM_INSTALL")" -eq 1
check "hook keeps the script valid" bash -n "$STEAM_INSTALL"
check "hook runs apply-wrap.sh" grep -qF 'SLSsteam/apply-wrap.sh' "$STEAM_INSTALL"
check "hook is placed after the client chmod" \
	test "$(grep -n 'chmod +x "\$steam_root/steamrtarm64/steam"' "$STEAM_INSTALL" | cut -d: -f1)" \
		-lt "$(grep -nF "$MARK_BEGIN" "$STEAM_INSTALL" | cut -d: -f1)"
check "hook install is idempotent" install_steam_install_hook
check "hook still installed once" \
	test "$(grep -cF "$MARK_BEGIN" "$STEAM_INSTALL")" -eq 1

# ---- legacy x86-64 launcher cleanup ---------------------------------------
printf '%s\n' '#!/bin/bash' 'echo launcher' > "$STEAM_X64_LAUNCHER.new"
mv "$STEAM_X64_LAUNCHER.new" "$STEAM_X64_LAUNCHER"
chmod +x "$STEAM_X64_LAUNCHER"
cat >> "$STEAM_X64_LAUNCHER" <<'SH'
# >>> SLSSTEAM-X64-INJECT
export LD_AUDIT=/old/SLSsteam.so
# <<< SLSSTEAM-X64-INJECT
SH
check "x86-64 launcher patch removed" cleanup_x86_launcher
check_not "x86-64 launcher marker gone" \
	grep -q 'SLSSTEAM-X64-INJECT' "$STEAM_X64_LAUNCHER"
check "x86-64 launcher keeps its own content" \
	grep -qF 'echo launcher' "$STEAM_X64_LAUNCHER"

# The old installer left a .luatools-orig copy; that one wins.
printf '#!/bin/bash\necho original\n' > "$STEAM_X64_LAUNCHER.luatools-orig"
printf '#!/bin/bash\necho patched\n' > "$STEAM_X64_LAUNCHER"
check "x86-64 launcher restored from the backup" cleanup_x86_launcher
check "backup restored verbatim" grep -qF 'echo original' "$STEAM_X64_LAUNCHER"
check "backup removed" test ! -e "$STEAM_X64_LAUNCHER.luatools-orig"

# ---- plugin reinstall keeps user data -------------------------------------
mkdir -p "$tmp/plug-src/public" "$tmp/plug-src/backend"
printf '{"name":"LuaTools"}\n' > "$tmp/plug-src/plugin.json"
printf 'console.log(1)\n' > "$tmp/plug-src/public/luatools.js"
printf -- '-- backend\n' > "$tmp/plug-src/backend/main.lua"
mkzip "$tmp/plug-src" "$tmp/luatools-linux.zip"
mkdir -p "$PLUGIN_DIR/backend/data"
printf '{"language":"pt-BR"}\n' > "$PLUGIN_DIR/backend/data/settings.json"
printf '{"token":"abc"}\n' > "$PLUGIN_DIR/backend/api.json"

install_sevenzip() { :; }   # the 7zz download is covered separately
PLUGIN_ZIP_URL="file://$tmp/luatools-linux.zip"
check "plugin installs from the archive" install_plugin
check "plugin manifest installed" test -f "$PLUGIN_DIR/plugin.json"
check "plugin frontend installed" test -f "$PLUGIN_DIR/public/luatools.js"
check "user settings survive a reinstall" \
	grep -q 'pt-BR' "$PLUGIN_DIR/backend/data/settings.json"
check "api.json survives a reinstall" \
	grep -q 'abc' "$PLUGIN_DIR/backend/api.json"
check "plugin reinstall" install_plugin
check "user settings survive a second reinstall" \
	grep -q 'pt-BR' "$PLUGIN_DIR/backend/data/settings.json"
check "no backup directory left behind" \
	test -z "$(find "$LUMEN_DIR" -maxdepth 1 -name '.plugin-data.*' 2>/dev/null)"

# The old x86-64 tree is migrated only for keys that do not exist yet.
mkdir -p "$LEGACY_HOME/.local/share/Lumen/luatools/backend/data"
printf '{"language":"en-US"}\n' > "$LEGACY_HOME/.local/share/Lumen/luatools/backend/data/settings.json"
printf '{"donated":[1]}\n' > "$LEGACY_HOME/.local/share/Lumen/luatools/backend/data/donated.json"
check "legacy plugin data migrates" migrate_legacy_data
check "missing legacy file migrated" test -f "$PLUGIN_DIR/backend/data/donated.json"
check "existing setting not overwritten" \
	grep -q 'pt-BR' "$PLUGIN_DIR/backend/data/settings.json"

# 7zz fallback: with no network and no p7zip, the installer warns and continues.
mkdir -p "$tmp/sevenzip"
SEVENZIP_URL="file://$tmp/does-not-exist.tar.xz"
check "missing 7zz download does not abort the install" install_sevenzip "$tmp/sevenzip"
check "no bogus 7zz installed" test ! -e "$tmp/sevenzip/bin/7zz"

# ---- verification ---------------------------------------------------------
check "verify passes on a complete install" verify

# ---- uninstall -------------------------------------------------------------
check "uninstall hook removal" uninstall_steam_install_hook
check_not "hook marker gone" grep -qF "$MARK_BEGIN" "$STEAM_INSTALL"
check "hook script still valid" bash -n "$STEAM_INSTALL"
check "uninstall" do_uninstall
check "steam launcher restored to the client" \
	test "$(elf_arch "$STEAM_BIN")" = aarch64
check_not "no wrapper left" grep -qF 'SLSsteam launcher wrapper' "$STEAM_BIN"
check "SLSsteam directory removed" test ! -d "$SLS_DIR"
check "Lumen directory removed" test ! -d "$LUMEN_DIR"
check "user data backed up on uninstall" \
	test -f "$SHARE/luatools-data-backup/settings.json"

printf '\n%d checks failed, %d skipped\n' "$fail" "$skipped"
exit "$fail"
