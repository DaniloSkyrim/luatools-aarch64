#!/usr/bin/env bash
# ============================================================================
#  luatools-aarch64 — LuaTools + SLSsteam + Lumen for DroidDeck (ARM64 host)
# ============================================================================
#  Target runtime:
#    * host:        aarch64 Linux inside the DroidDeck desktop (Ubuntu 26.04
#                   on current images; Arch Linux ARM on older ones)
#    * Steam:       DroidDeck's x86-64 client (steamrt64/steam) under FEX
#
#  What this installs:
#    1. SLSsteam x86-64 (upstream AceSLS/SLSsteam dev-X86_64) into
#       ~/.droiddeck-x64/.local/share/SLSsteam
#    2. Lumen aarch64 (built from swwayps/lumen) into
#       ~/.droiddeck-x64/.local/share/Lumen
#    3. The LuaTools plugin (swwayps/luatools-moon) into
#       ~/.droiddeck-x64/.local/share/Lumen/luatools
#    4. An aarch64 7zz for the plugin's backend
#    5. A small, idempotent patch in /usr/local/bin/droiddeck-steam-x64 that
#       starts Lumen natively and injects SLSsteam into the FEX guest via
#       `FEX /usr/bin/env LD_AUDIT=... steam` (never into the aarch64 host).
#
#  Usage:
#    curl -fsSL <this script> | bash
#    bash install.sh --build          # build SLSsteam on-device if no release
#    bash install.sh --uninstall
#    bash install.sh --help
#
#  The only value you may need to edit before publishing this repository is
#  REPO_SLUG below (or pass LUA_TOOLS_REPO=owner/repo in the environment).
# ============================================================================
set -uo pipefail

REPO_SLUG="${LUA_TOOLS_REPO:-DaniloSkyrim/luatools-aarch64}"
SLS_RELEASE_URL="${SLS_RELEASE_URL:-https://github.com/$REPO_SLUG/releases/download/slsteam-x86_64/slsteam-x86_64.zip}"
SLS_SOURCE_URL="${SLS_SOURCE_URL:-https://codeload.github.com/AceSLS/SLSsteam/tar.gz/refs/heads/dev-X86_64}"
# Pinned to the commit whose lua/proc.lua and lua/about.lua the patches below
# were written against.
LUMEN_SOURCE_URL="${LUMEN_SOURCE_URL:-https://codeload.github.com/swwayps/lumen/tar.gz/52475c3ec0bbe2bf0ccdd209d86a40d99a9881fa}"
PLUGIN_ZIP_URL="${PLUGIN_ZIP_URL:-https://github.com/swwayps/luatools-moon/releases/latest/download/luatools-linux.zip}"
CLOUDREDIRECT_URL="${CLOUDREDIRECT_URL:-https://github.com/$REPO_SLUG/releases/download/slsteam-x86_64/cloudredirect-x86_64.zip}"
SEVENZIP_URL="${SEVENZIP_URL:-https://github.com/ip7z/7zip/releases/download/26.05/7z2605-linux-arm64.tar.xz}"

OPT_BUILD=0
OPT_UNINSTALL=0

X64_HOME="${BL_X64_HOME:-$HOME/.droiddeck-x64}"
STEAM_X64="$X64_HOME/.local/share/Steam"
SHARE="$X64_HOME/.local/share"
SLS_DIR="$SHARE/SLSsteam"
LUMEN_DIR="$SHARE/Lumen"
DROIDDECK_X64="/usr/local/bin/droiddeck-steam-x64"
FEX_ROOTFS="$X64_HOME/rootfs"
MARK_BEGIN="# >>> SLSSTEAM-X64-INJECT"
MARK_END="# <<< SLSSTEAM-X64-INJECT"

# ----------------------------------------------------------------------------
# output
# ----------------------------------------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
	B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
	B=""; G=""; Y=""; R=""; C=""; N=""
fi
step() { printf '%s==>%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s ok%s  %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s  %s\n' "$Y" "$N" "$*"; }
die()  { printf '%sfail%s  %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

usage() {
	cat <<'EOF'
luatools-aarch64 installer for DroidDeck (x86-64 Steam under FEX)

  --build        build SLSsteam x86-64 on-device inside DroidDeck's FEX rootfs
                 when the prebuilt release asset is unavailable
  --uninstall    remove SLSsteam, Lumen and the installer's patch
  --help         this text

Environment:
  LUA_TOOLS_REPO=owner/repo   repository serving the SLSsteam release
  SLS_RELEASE_URL=<url>       explicit slsteam-x86_64.zip URL
  BL_X64_HOME=<dir>           DroidDeck x86-64 home (default ~/.droiddeck-x64)
EOF
}

parse_args() {
	for a in "$@"; do
		case "$a" in
			--build) OPT_BUILD=1 ;;
			--uninstall) OPT_UNINSTALL=1 ;;
			--help|-h) usage; exit 0 ;;
			# Accepted for compatibility with Lumen's Update All button.
			--slsteam-channel|--plugin-channel|--lumen-channel) : ;;
			stable|beta) : ;;
			--noplugin) : ;;
			*) die "unknown option: $a (see --help)" ;;
		esac
	done
}

# ----------------------------------------------------------------------------
# environment detection
# ----------------------------------------------------------------------------
detect() {
	local arch
	arch="$(uname -m)"
	[ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ] || \
		die "this installer targets aarch64 (got $arch). The host must be the ARM64 DroidDeck runtime."

	[ -x "$DROIDDECK_X64" ] || \
		die "DroidDeck's x86-64 launcher not found at $DROIDDECK_X64. Run this inside the DroidDeck desktop."

	if [ ! -f "$STEAM_X64/steamrt64/steamclient.so" ]; then
		warn "x86-64 Steam client not found under $STEAM_X64"
		step "asking DroidDeck to prepare its x86-64 client and FEX rootfs"
		"$DROIDDECK_X64" --prepare || warn "--prepare failed; continuing"
	fi

	[ -f "$STEAM_X64/steamrt64/steamclient.so" ] || die \
"x86-64 Steam is not ready.

  1. In the DroidDeck app, enable the x86-64 Steam client
     (Steam client architecture = x86-64).
  2. Launch Steam once from the DroidDeck desktop so it downloads steamrt64.
  3. Run this installer again."

	[ -f "$FEX_ROOTFS/usr/bin/env" ] || warn \
"$FEX_ROOTFS/usr/bin/env is missing; the LD_AUDIT injection needs it. Re-run after Steam's first x86-64 launch."

	ok "host aarch64, DroidDeck x86-64 launcher and steamrt64 client found"
}

# ----------------------------------------------------------------------------
# dependencies
# ----------------------------------------------------------------------------
ensure_deps() {
	local missing=() p
	for p in curl tar unzip python3 gcc make pkg-config file; do
		have "$p" || missing+=("$p")
	done
	if [ "${#missing[@]}" -eq 0 ]; then
		ok "build tools present"
		return 0
	fi

	local SUDO=""
	if [ "$(id -u)" -ne 0 ]; then
		have sudo || die "missing ${missing[*]} and neither root nor sudo is available"
		SUDO="sudo"
	fi

	# DroidDeck's current LinuxFS is Ubuntu (apt); older/other images are Arch
	# Linux ARM (pacman). Lumen needs a C compiler plus the lua5.4 and libcurl
	# development files.
	if have apt-get; then
		step "installing build dependencies with apt-get: ${missing[*]}"
		$SUDO apt-get update -qq || warn "apt-get update failed; trying the install anyway"
		DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends \
			build-essential pkg-config liblua5.4-dev libcurl4-openssl-dev \
			ca-certificates curl unzip python3 file tar xz-utils zstd >/dev/null || \
			die "apt-get could not install the build dependencies"
	elif have pacman; then
		step "installing build dependencies with pacman: ${missing[*]}"
		# lua54/curl/openssl are Lumen build deps; base-devel supplies gcc, make, pkgconf.
		$SUDO pacman -S --needed --noconfirm base-devel lua54 curl openssl unzip python tar xz file >/dev/null || \
			die "pacman could not install the build dependencies"
	else
		die "missing ${missing[*]} and neither apt-get nor pacman is available; install them and re-run"
	fi
	have gcc && have make && have pkg-config || die "build tools still missing after the package manager"
	ok "build dependencies installed"
}

# ----------------------------------------------------------------------------
# download helper
# ----------------------------------------------------------------------------
fetch() {
	local url="$1" out="$2"
	curl -fL --retry 3 --connect-timeout 20 --max-time 600 -o "$out" "$url"
}

# ----------------------------------------------------------------------------
# SLSsteam x86-64
# ----------------------------------------------------------------------------
install_slsteam_from_zip() {
	local zip="$1" root="$2"
	local d
	d="$(find "$root" -maxdepth 2 -type d -name 'slsteam-x86_64' | head -n1)"
	[ -n "$d" ] || d="$root"
	[ -f "$d/bin/SLSsteam.so" ] || return 1
	file -b "$d/bin/SLSsteam.so" | grep -q 'ELF 64-bit' || {
		warn "SLSsteam.so in the release is not ELF64: $(file -b "$d/bin/SLSsteam.so")"
		return 1
	}
	mkdir -p "$SLS_DIR/bin" "$SLS_DIR/res"
	install -m 0755 "$d/bin/SLSsteam.so" "$SLS_DIR/SLSsteam.so"
	rm -f "$SLS_DIR/library-inject.so"
	# dev-X86_64 ships library-inject.so as an empty placeholder.
	if [ -s "$d/bin/library-inject.so" ] && file -b "$d/bin/library-inject.so" | grep -q 'ELF 64-bit'; then
		install -m 0755 "$d/bin/library-inject.so" "$SLS_DIR/library-inject.so"
	fi
	[ -f "$d/res/config.yaml" ] && install -m 0644 "$d/res/config.yaml" "$SLS_DIR/res/config.yaml"
	ok "SLSsteam x86-64 installed in $SLS_DIR"
}

build_slsteam_on_device() {
	local src="$1"
	[ -x "$FEX_ROOTFS/usr/bin/bash" ] || die \
		"cannot build on-device: $FEX_ROOTFS/usr/bin/bash is missing (launch x86-64 Steam once first)"
	local fex="${BL_FEX:-/usr/local/bin/FEX}"
	[ -x "$fex" ] || die "FEX not found at $fex"

	step "unpacking SLSsteam source into the x86-64 rootfs (on-device build)"
	rm -rf "$FEX_ROOTFS/tmp/slsteam-build"
	mkdir -p "$FEX_ROOTFS/tmp/slsteam-build"
	tar -xzf "$src" -C "$FEX_ROOTFS/tmp/slsteam-build" --strip-components=1 || \
		die "could not unpack the SLSsteam source"

	step "installing the x86-64 toolchain inside the FEX rootfs (apt, may take a while)"
	FEX_ROOTFS="$FEX_ROOTFS" "$fex" /usr/bin/env \
		HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		DEBIAN_FRONTEND=noninteractive \
		/usr/bin/bash -c 'apt-get update && apt-get install -y --no-install-recommends \
			build-essential pkg-config libssl-dev libcurl4-openssl-dev libdbus-1-dev' || \
		die "apt-get inside the FEX rootfs failed"

	step "compiling SLSsteam x86-64 under FEX (this is slow)"
	FEX_ROOTFS="$FEX_ROOTFS" "$fex" /usr/bin/env \
		HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		/usr/bin/bash -c 'cd /tmp/slsteam-build && make -j"$(nproc)" audit-libs' || \
		die "SLSsteam build failed"

	local b="$FEX_ROOTFS/tmp/slsteam-build/bin"
	[ -f "$b/SLSsteam.so" ] || die "build produced no bin/SLSsteam.so"
	mkdir -p "$SLS_DIR"
	install -m 0755 "$b/SLSsteam.so" "$SLS_DIR/SLSsteam.so"
	rm -f "$SLS_DIR/library-inject.so"
	if [ -s "$b/library-inject.so" ] && file -b "$b/library-inject.so" | grep -q 'ELF 64-bit'; then
		install -m 0755 "$b/library-inject.so" "$SLS_DIR/library-inject.so"
	fi
	[ -f "$FEX_ROOTFS/tmp/slsteam-build/res/config.yaml" ] && \
		install -D -m 0644 "$FEX_ROOTFS/tmp/slsteam-build/res/config.yaml" "$SLS_DIR/res/config.yaml"
	rm -rf "$FEX_ROOTFS/tmp/slsteam-build"
	ok "SLSsteam x86-64 built and installed in $SLS_DIR"
}

install_slsteam() {
	TMP="$(mktemp -d)"
	local zip="$TMP/slsteam-x86_64.zip" root="$TMP/slsteam"
	step "downloading SLSsteam x86-64"
	if fetch "$SLS_RELEASE_URL" "$zip" 2>/dev/null; then
		mkdir -p "$root"
		unzip -qo "$zip" -d "$root" || die "could not unpack $zip"
		if install_slsteam_from_zip "$zip" "$root"; then
			install_slsteam_shims
			return 0
		fi
		warn "the release asset did not contain a usable x86-64 SLSsteam"
	else
		warn "no prebuilt SLSsteam at $SLS_RELEASE_URL"
	fi

	if [ "$OPT_BUILD" -eq 1 ]; then
		step "downloading SLSsteam source"
		fetch "$SLS_SOURCE_URL" "$TMP/slsteam-src.tar.gz" || die "could not download the SLSsteam source"
		build_slsteam_on_device "$TMP/slsteam-src.tar.gz"
		install_slsteam_shims
		return 0
	fi

	die "no prebuilt SLSsteam x86-64 available.

  Publish the release once (GitHub Actions workflow
  .github/workflows/build-slsteam-x86_64.yml), or re-run with --build to
  compile it on-device inside DroidDeck's FEX rootfs (slow)."
}

# The LuaTools backend's restart_steam.sh prefers
# $HOME/.local/share/SLSsteam/path/steam. Point it at the DroidDeck launcher;
# the launcher's patched x64_exec does the actual injection. The desktop
# guardian is not used here (no systemd user units under PRoot), so provide a
# successful no-op for Lumen's deskcover calls.
install_slsteam_shims() {
	mkdir -p "$SLS_DIR/path"
	cat > "$SLS_DIR/path/steam" <<'EOF'
#!/bin/sh
# Lumen runs with HOME=$X64_HOME (see x64_env), but droiddeck-steam-x64 derives
# its own X64_HOME from HOME. Restore the outer home before calling it, or the
# relaunch would create a nested ~/.droiddeck-x64 and bootstrap a second client.
x64="${BL_X64_HOME:-}"
if [ -z "$x64" ]; then
	d=$(cd "$(dirname "$0")" && pwd)
	x64=$(dirname "$(dirname "$(dirname "$(dirname "$d")")")")
fi
if [ "$HOME" = "$x64" ]; then
	HOME=$(dirname "$x64"); export HOME
fi
exec /usr/local/bin/droiddeck-steam-x64 --exec "$@"
EOF
	chmod 0755 "$SLS_DIR/path/steam"
	cat > "$SLS_DIR/ensure-desktop-coverage.sh" <<'EOF'
#!/bin/sh
# Desktop coverage is handled by the droiddeck-steam-x64 injection block.
exit 0
EOF
	chmod 0755 "$SLS_DIR/ensure-desktop-coverage.sh"
	# Seed the runtime config so the LuaTools settings tab has a file to read
	# before the first injected Steam launch.
	if [ -f "$SLS_DIR/res/config.yaml" ] && [ ! -f "$X64_HOME/.config/SLSsteam/config.yaml" ]; then
		mkdir -p "$X64_HOME/.config/SLSsteam"
		install -m 0644 "$SLS_DIR/res/config.yaml" "$X64_HOME/.config/SLSsteam/config.yaml"
	fi
	ok "SLSsteam launcher shims installed"
}

# ----------------------------------------------------------------------------
# Lumen (aarch64)
# ----------------------------------------------------------------------------
install_lumen() {
	TMP="${TMP:-$(mktemp -d)}"
	local src="$TMP/lumen-src"
	step "downloading Lumen source"
	fetch "$LUMEN_SOURCE_URL" "$TMP/lumen.tar.gz" || die "could not download Lumen"
	mkdir -p "$src"
	tar -xzf "$TMP/lumen.tar.gz" -C "$src" --strip-components=1 || die "could not unpack Lumen"

	step "building Lumen for aarch64"
	( cd "$src" && make -j"$(nproc)" ) || die "Lumen build failed"
	[ -x "$src/bin/lumen" ] || die "Lumen build produced no bin/lumen"
	file -b "$src/bin/lumen" | grep -q 'ELF 64-bit.*aarch64' || die "Lumen is not ELF64 aarch64"

	mkdir -p "$LUMEN_DIR"
	install -m 0755 "$src/bin/lumen" "$LUMEN_DIR/lumen"
	rm -rf "$LUMEN_DIR/lua"
	cp -r "$src/lua" "$LUMEN_DIR/lua"
	patch_lumen_proc "$LUMEN_DIR/lua/proc.lua" || \
		warn "Lumen will not recognise the FEX Steam process; the LuaTools UI may detach"
	patch_lumen_restart "$LUMEN_DIR/lua/restart_steam.sh" || \
		warn "Lumen's Restart Steam cannot see the FEX client; restart it from the desktop"
	patch_lumen_about "$LUMEN_DIR/lua/about.lua" || \
		warn "Lumen's Update All still points at the i386 moon stack; do not use it"
	ok "Lumen installed in $LUMEN_DIR"
}

# Lumen's Update All button re-runs the upstream luatools-moon installer, which
# would replace this x86-64 setup with the i386 moon stack. Point it at this
# repository's installer instead; the installer is idempotent.
patch_lumen_about() {
	local f="$1"
	[ -f "$f" ] || { warn "Lumen about.lua not found; skipping update URL patch"; return 0; }
	grep -q 'SLSSTEAM-AARCH64-UPDATE-URL' "$f" && return 0
	python3 - "$f" "$REPO_SLUG" <<'PY' || { warn "could not patch Lumen about.lua"; return 1; }
import sys
path, repo = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
old = "https://raw.githubusercontent.com/swwayps/luatools-moon/main/install.sh"
new = "https://raw.githubusercontent.com/%s/main/install.sh" % repo
if old not in src:
    raise SystemExit("upstream install URL not found")
src = src.replace(old, new, 1)
src = src.replace("about.INSTALL_URL =",
                  "-- SLSSTEAM-AARCH64-UPDATE-URL\nabout.INSTALL_URL =", 1)
open(path, "w", encoding="utf-8").write(src)
PY
	ok "Lumen Update All points at this repository"
}

# DroidDeck runs the x86-64 Steam client under FEX, so /proc/<pid>/comm is
# FEX/FEXInterpreter, not "steam". Lumen's liveness and SLSsteam-detection
# checks match comm exactly; teach them to recognise the FEX guest by cmdline.
patch_lumen_proc() {
	local f="$1"
	[ -f "$f" ] || { warn "Lumen proc.lua not found; skipping FEX match patch"; return 0; }
	grep -q 'SLSSTEAM-FEX-MATCH' "$f" && return 0
	python3 - "$f" <<'PY' || { warn "could not patch Lumen proc.lua for FEX"; return 1; }
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
helper = '''-- SLSSTEAM-FEX-MATCH: the x86-64 Steam client (and its helpers) run under
-- FEX, so /proc/<pid>/comm is FEX/FEXInterpreter rather than "steam". Match the
-- guest command line instead: the emulated binary is an argument ending in
-- "/<comm>" (NUL-separated argv), which does not confuse steam with
-- steamwebhelper.
local function sls_match(comm, name, root, entry)
  if name == comm then return true end
  if type(name) ~= "string" or not name:match("^FEX") then return false end
  local fh = io.open(root .. "/" .. entry .. "/cmdline", "rb")
  if not fh then return false end
  local line = fh:read("*a")
  fh:close()
  if not line then return false end
  local arg = "/" .. comm
  return line:find(arg .. "\\0", 1, true) ~= nil or line:sub(-#arg) == arg
end
'''
src = src.replace("local proc = {}\n", "local proc = {}\n\n" + helper, 1)
src = src.replace("if name == comm then found = true; break end",
                  "if sls_match(comm, name, root, entry) then found = true; break end", 1)
src = src.replace("        if name == comm then\n",
                  "        if sls_match(comm, name, root, entry) then\n", 1)
open(path, "w", encoding="utf-8").write(src)
PY
	ok "Lumen proc.lua taught to recognise the FEX Steam process"
}

# Lumen's Restart Steam helper uses `pgrep -x steam` / `pkill -x steam`, which
# never match a FEX guest. Without this it reports the client as already gone
# and refuses to relaunch.
patch_lumen_restart() {
	local f="$1"
	[ -f "$f" ] || { warn "Lumen restart_steam.sh not found; skipping FEX match patch"; return 0; }
	grep -q 'SLSSTEAM-FEX-MATCH' "$f" && return 0
	python3 - "$f" <<'PY' || { warn "could not patch Lumen restart_steam.sh for FEX"; return 1; }
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()

anchor = 'CHECK_ONLY="${1:-}"\n'
if anchor not in src:
    raise SystemExit("CHECK_ONLY anchor not found")

src = src.replace("pgrep -x steam >/dev/null 2>&1", "sls_steam_alive")
src = src.replace("pkill -TERM -x steam >/dev/null 2>&1 || true", "sls_signal_steam TERM")
src = src.replace("pkill -KILL -x steam >/dev/null 2>&1 || true", "sls_signal_steam KILL")

helper = '''
# SLSSTEAM-FEX-MATCH: the x86-64 client runs under FEX, so its comm is
# FEX/FEXInterpreter rather than "steam". Match the guest cmdline too.
sls_steam_alive() {
  pgrep -x steam >/dev/null 2>&1 || pgrep -f 'steamrt64/steam( |$)' >/dev/null 2>&1
}
sls_signal_steam() {
  pkill -"$1" -x steam >/dev/null 2>&1 || true
  pkill -"$1" -f 'steamrt64/steam( |$)' >/dev/null 2>&1 || true
}
'''
src = src.replace(anchor, anchor + helper, 1)
open(path, "w", encoding="utf-8").write(src)
PY
	ok "Lumen restart helper taught to recognise the FEX Steam process"
}

# ----------------------------------------------------------------------------
# LuaTools plugin + 7zz
# ----------------------------------------------------------------------------
install_sevenzip() {
	mkdir -p "$1/bin"
	local dest="$1/bin/7zz"
	local tmpd="$TMP/7z"
	mkdir -p "$tmpd"
	if curl -fL --retry 2 -o "$TMP/7z.tar.xz" "$SEVENZIP_URL" 2>/dev/null && \
		tar -xJf "$TMP/7z.tar.xz" -C "$tmpd" 2>/dev/null; then
		local z
		z="$(find "$tmpd" -maxdepth 3 -type f -name 7zz | head -n1)"
		if [ -n "$z" ] && file -b "$z" | grep -q 'ELF 64-bit.*aarch64'; then
			install -m 0755 "$z" "$dest"
			ok "aarch64 7zz installed for the plugin backend"
			return 0
		fi
	fi
	warn "could not fetch the official aarch64 7zz; falling back to p7zip"
	local SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
	if have apt-get; then
		$SUDO apt-get install -y --no-install-recommends p7zip-full >/dev/null 2>&1 || true
	elif have pacman; then
		$SUDO pacman -S --needed --noconfirm p7zip >/dev/null 2>&1 || true
	fi
	if [ -x /usr/bin/7z ]; then
		printf '#!/bin/sh\nexec /usr/bin/7z "$@"\n' > "$dest"
		chmod 0755 "$dest"
		ok "p7zip shim installed as the plugin's 7zz"
	else
		warn "no 7z backend available; .rar extraction in the plugin will not work"
	fi
}

install_plugin() {
	local zip="$TMP/luatools-linux.zip" root="$TMP/plugin"
	step "downloading the LuaTools plugin"
	fetch "$PLUGIN_ZIP_URL" "$zip" || die "could not download luatools-linux.zip"
	mkdir -p "$root"
	unzip -qo "$zip" -d "$root" || die "could not unpack the LuaTools plugin"
	local pj
	pj="$(find "$root" -maxdepth 2 -name plugin.json -type f | head -n1)"
	[ -n "$pj" ] || die "the plugin archive has no plugin.json"
	local srcdir; srcdir="$(dirname "$pj")"
	local dest="$LUMEN_DIR/luatools"
	# The plugin keeps its settings and donated appid list under
	# backend/data; a reinstall must not reset them. api.json is the legacy
	# location of the user's API list and is migrated into data on restore.
	local data_bak=""
	if [ -d "$dest/backend/data" ] || [ -f "$dest/backend/api.json" ]; then
		# Sibling of $dest so the backup survives even if $TMP is cleaned up.
		data_bak="$LUMEN_DIR/.plugin-data.$$"
		mkdir -p "$data_bak" || die "could not create the plugin backup directory"
		if [ -d "$dest/backend/data" ] && \
			! cp -a "$dest/backend/data/." "$data_bak/" 2>/dev/null; then
			rm -rf "$data_bak"
			die "could not back up the LuaTools settings; reinstall aborted"
		fi
		if [ ! -f "$data_bak/api.json" ] && [ -f "$dest/backend/api.json" ]; then
			cp -a "$dest/backend/api.json" "$data_bak/api.json" 2>/dev/null || true
		fi
	fi

	rm -rf "$dest"
	mkdir -p "$dest"
	cp -r "$srcdir"/. "$dest"/

	if [ -n "$data_bak" ]; then
		mkdir -p "$dest/backend/data"
		if cp -a "$data_bak/." "$dest/backend/data/" 2>/dev/null; then
			rm -rf "$data_bak"
			ok "previous LuaTools settings restored"
		else
			warn "could not restore the previous LuaTools settings (kept in $data_bak)"
		fi
	fi

	install_sevenzip "$dest/backend"
	ok "LuaTools plugin installed in $dest"
}

# CloudRedirect is best-effort: it is only useful if the x86-64 build exists.
# The hook is injected in the guest via LD_PRELOAD by the launcher patch.
install_cloudredirect() {
	local zip="$TMP/cloudredirect-x86_64.zip" root="$TMP/cr"
	if ! fetch "$CLOUDREDIRECT_URL" "$zip" 2>/dev/null; then
		warn "CloudRedirect x86-64 not published; cloud saves stay disabled"
		return 0
	fi
	mkdir -p "$root"
	if ! unzip -qo "$zip" -d "$root" 2>/dev/null; then
		warn "CloudRedirect archive is invalid; cloud saves stay disabled"
		return 0
	fi
	local so cli
	so="$(find "$root" -name cloud_redirect.so -type f | head -n1)"
	cli="$(find "$root" -name cloud_redirect_cli -type f | head -n1)"
	if [ -z "$so" ] || [ -z "$cli" ] || ! file -b "$so" | grep -q 'ELF 64-bit.*x86-64'; then
		warn "CloudRedirect is not a usable x86-64 build; cloud saves stay disabled"
		return 0
	fi
	mkdir -p "$SHARE/CloudRedirect"
	install -m 0755 "$so" "$SHARE/CloudRedirect/cloud_redirect.so"
	# Lumen runs on the ARM64 host, so it cannot exec the x86-64 CLI directly;
	# wrap it in FEX using the guest rootfs Steam already uses.
	install -m 0755 "$cli" "$SHARE/CloudRedirect/cloud_redirect_cli.bin"
	cat > "$SHARE/CloudRedirect/cloud_redirect_cli" <<'EOF'
#!/bin/sh
# x86-64 CLI launched through FEX; the x86-64 home is three levels above
# this script (.local/share/CloudRedirect), so it works from any shell.
dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || dir=$(dirname "$0")
x64=$(dirname "$(dirname "$(dirname "$dir")")")
exec env FEX_ROOTFS="$x64/rootfs" "${BL_FEX:-/usr/local/bin/FEX}" \
  "$dir/cloud_redirect_cli.bin" "$@"
EOF
	chmod 0755 "$SHARE/CloudRedirect/cloud_redirect_cli"
	ok "CloudRedirect x86-64 installed in $SHARE/CloudRedirect"
}

# ----------------------------------------------------------------------------
# /usr/local/bin/droiddeck-steam-x64 patch
# ----------------------------------------------------------------------------
patch_droiddeck() {
	local f="$DROIDDECK_X64" orig="$DROIDDECK_X64.luatools-orig"
	[ -f "$f" ] || die "$f not found"
	if grep -qF "$MARK_BEGIN" "$f"; then
		ok "droiddeck-steam-x64 is already patched"
		return 0
	fi
	[ -w "$f" ] || [ "$(id -u)" -eq 0 ] || die "$f is not writable; re-run as root (DroidDeck's guest user is usually root)"

	step "patching $f (inject SLSsteam into the FEX guest only)"
	# The file is known-unpatched here, so refresh the backup: a DroidDeck
	# update may have replaced the launcher since the previous install.
	cp -p "$f" "$orig"

	SLS_PATCH_FILE="$f" SLS_BEGIN="$MARK_BEGIN" SLS_END="$MARK_END" python3 - <<'PY'
import os, sys

path = os.environ["SLS_PATCH_FILE"]
begin = os.environ["SLS_BEGIN"]
end = os.environ["SLS_END"]

src = open(path, encoding="utf-8", errors="surrogateescape").read()
if begin in src:
    print("already patched")
    sys.exit(0)

needle = 'exec "${BL_FEX:-/usr/local/bin/FEX}" "$STEAM_X64/steamrt64/steam" "$@"'
if needle not in src:
    sys.exit("could not find the FEX exec line in droiddeck-steam-x64")

block = f'''{begin}
  if [ -z "${{SLS_DISABLE:-}}" ]; then
    # Never let the host (aarch64) loader see the guest's x86-64 audit lib.
    unset LD_AUDIT
    SLS_SHARE="${{X64_HOME:-$HOME/.droiddeck-x64}}/.local/share"
    SLS_AUDIT_LIBS="$SLS_SHARE/SLSsteam/SLSsteam.so"
    [ -s "$SLS_SHARE/SLSsteam/library-inject.so" ] && \\
      SLS_AUDIT_LIBS="$SLS_SHARE/SLSsteam/library-inject.so:$SLS_AUDIT_LIBS"
    if [ -x "$SLS_SHARE/Lumen/lumen" ] && ! pgrep -f "$SLS_SHARE/Lumen/lumen" >/dev/null 2>&1; then
      touch "$STEAM_X64/.cef-enable-remote-debugging" 2>/dev/null || true
      env -u LD_AUDIT -u LD_PRELOAD -u LD_LIBRARY_PATH -u FEX_ROOTFS \\
          -u FEX_THUNKCONFIG -u FEX_THUNKHOSTLIBS -u FEX_THUNKGUESTLIBS \\
          PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
          BL_X64_HOME="$X64_HOME" \\
          LUMEN_SINGLETON_LOCK="$SLS_SHARE/Lumen/lumen.lock" \\
          LUMEN_BACKEND_DIR="$SLS_SHARE/Lumen/luatools/backend" \\
          LUMEN_LUA_DIR="$SLS_SHARE/Lumen/lua" \\
          setsid "$SLS_SHARE/Lumen/lumen" >/dev/null 2>&1 < /dev/null &
    fi
    SLS_PRELOAD=""
    [ -f "$SLS_SHARE/CloudRedirect/cloud_redirect.so" ] && \\
      SLS_PRELOAD="$SLS_SHARE/CloudRedirect/cloud_redirect.so"
    if [ -f "$SLS_SHARE/SLSsteam/SLSsteam.so" ]; then
      if [ -n "$SLS_PRELOAD" ]; then
        exec "${{BL_FEX:-/usr/local/bin/FEX}}" /usr/bin/env LD_PRELOAD="$SLS_PRELOAD" \\
          LD_AUDIT="$SLS_AUDIT_LIBS" "$STEAM_X64/steamrt64/steam" "$@"
      fi
      exec "${{BL_FEX:-/usr/local/bin/FEX}}" /usr/bin/env \\
        LD_AUDIT="$SLS_AUDIT_LIBS" "$STEAM_X64/steamrt64/steam" "$@"
    fi
  fi
{end}
{needle}'''

tmp = path + ".luatools-new"
with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as fh:
    fh.write(src.replace(needle, block, 1))
os.replace(tmp, path)
print("patched")
PY
	[ $? -eq 0 ] || die "patching droiddeck-steam-x64 failed"
	ok "droiddeck-steam-x64 patched"
}

unpatch_droiddeck() {
	local f="$DROIDDECK_X64" orig="$DROIDDECK_X64.luatools-orig"
	if [ -f "$orig" ]; then
		cp -p "$orig" "$f" && rm -f "$orig"
		ok "droiddeck-steam-x64 restored from backup"
		return 0
	fi
	[ -f "$f" ] || return 0
	python3 - "$f" "$MARK_BEGIN" "$MARK_END" <<'PY' || true
import re, sys
path, begin, end = sys.argv[1:4]
src = open(path, encoding="utf-8", errors="surrogateescape").read()
src2 = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n", "", src, flags=re.S)
if src2 != src:
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(src2)
    print("removed patch block")
PY
	ok "droiddeck-steam-x64 cleaned"
}

# ----------------------------------------------------------------------------
# verification
# ----------------------------------------------------------------------------
verify() {
	local bad=0
	if [ -f "$SLS_DIR/SLSsteam.so" ]; then
		file -b "$SLS_DIR/SLSsteam.so" | grep -q 'ELF 64-bit.*x86-64' && \
			ok "SLSsteam.so is x86-64" || { warn "SLSsteam.so has the wrong architecture"; bad=1; }
	fi
	if [ -f "$LUMEN_DIR/lumen" ]; then
		file -b "$LUMEN_DIR/lumen" | grep -q 'ELF 64-bit.*aarch64' && \
			ok "lumen is aarch64" || { warn "lumen has the wrong architecture"; bad=1; }
	fi
	[ -f "$LUMEN_DIR/luatools/plugin.json" ] && ok "LuaTools plugin present" || { warn "LuaTools plugin missing"; bad=1; }
	grep -q 'SLSSTEAM-FEX-MATCH' "$LUMEN_DIR/lua/proc.lua" 2>/dev/null && \
		ok "Lumen recognises the FEX Steam process" || { warn "Lumen's FEX process match is missing"; bad=1; }
	grep -q 'SLSSTEAM-AARCH64-UPDATE-URL' "$LUMEN_DIR/lua/about.lua" 2>/dev/null && \
		ok "Lumen Update All points at this repository" || { warn "Lumen Update All still points upstream"; bad=1; }
	[ -x "$LUMEN_DIR/luatools/backend/bin/7zz" ] && \
		ok "aarch64 7zz present for the plugin backend" || warn "no 7zz binary in the plugin backend"
	if [ -f "$SHARE/CloudRedirect/cloud_redirect.so" ]; then
		file -b "$SHARE/CloudRedirect/cloud_redirect.so" | grep -q 'ELF 64-bit.*x86-64' && \
			ok "CloudRedirect is x86-64" || { warn "CloudRedirect has the wrong architecture"; bad=1; }
	else
		warn "CloudRedirect absent (cloud saves disabled)"
	fi
	grep -qF "$MARK_BEGIN" "$DROIDDECK_X64" && ok "x86-64 launcher patched" || { warn "x86-64 launcher not patched"; bad=1; }
	[ -s "$SLS_DIR/SLSsteam.so" ] || { warn "SLSsteam.so missing"; bad=1; }
	return "$bad"
}

# ----------------------------------------------------------------------------
# uninstall
# ----------------------------------------------------------------------------
do_uninstall() {
	step "removing the installer's patch"
	unpatch_droiddeck
	step "removing SLSsteam, Lumen and CloudRedirect from $SHARE"
	rm -rf "$SLS_DIR" "$LUMEN_DIR" "$SHARE/CloudRedirect"
	rm -f "$X64_HOME/.config/SLSsteam/config.yaml" 2>/dev/null || true
	ok "uninstalled (the Steam client itself was not touched)"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
	parse_args "$@"
	printf '%s\n' "luatools-aarch64 — LuaTools + SLSsteam + Lumen for DroidDeck"
	if [ "$OPT_UNINSTALL" -eq 1 ]; then
		do_uninstall
		return 0
	fi

	detect
	ensure_deps
	install_slsteam
	install_lumen
	install_plugin
	install_cloudredirect
	patch_droiddeck

	echo
	if verify; then

		cat <<EOF
${B}Instalação concluída.${N}

  Inicie a Steam pelo ícone normal do DroidDeck (modo x86-64).
  O launcher inicia o Lumen nativamente e injeta o SLSsteam no guest FEX.

  Verificação:
    pgrep -af 'SLSsteam|Lumen/lumen'
    grep -m1 SLSsteam /proc/\$(pgrep -f 'steamrt64/steam' | head -n1)/maps

  Log do Lumen: $X64_HOME/.lumen.log
  Desativar a injeção numa sessão: SLS_DISABLE=1 steam
EOF
	else
		warn "a instalação terminou com pendências; veja os avisos acima"
		return 1
	fi
}

# Source with LUATOOLS_LIB_ONLY=1 to unit-test individual functions (tests/).
if [ "${LUATOOLS_LIB_ONLY:-0}" != "1" ]; then
	main "$@"
fi
