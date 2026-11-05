#!/usr/bin/env bash
# ============================================================================
#  luatools-aarch64 — LuaTools + SLSsteam + Lumen for DroidDeck (native ARM64)
# ============================================================================
#  Target runtime:
#    * host:  aarch64 Linux inside the DroidDeck desktop (Ubuntu 26.04 on
#             current images, Arch Linux ARM on older ones)
#    * Steam: DroidDeck's **native aarch64** client
#             ($HOME/.local/share/Steam/steamrtarm64/steam), desktop and
#             Game Mode alike. The x86-64 client under FEX is not touched.
#
#  What this installs:
#    1. SLSsteam aarch64 (native port, patched signature table for the current
#       steamrtarm64/steamclient.so) into ~/.local/share/SLSsteam
#    2. Lumen aarch64 into ~/.local/share/Lumen
#    3. The LuaTools plugin (swwayps/luatools-moon) into
#       ~/.local/share/Lumen/luatools, preserving backend/data
#    4. An aarch64 7zz for the plugin backend
#    5. A launcher wrapper: steamrtarm64/steam -> steam.real, so SLSsteam is
#       injected through LD_AUDIT and Lumen starts with the client
#    6. An idempotent hook in droiddeck-steam-install that re-applies the
#       wrapper at every session start and after a Steam client update
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/DaniloSkyrim/luatools-aarch64/main/install.sh | bash
#    bash install.sh --uninstall
#    bash install.sh --help
#
#  Everything is written under $HOME inside the DroidDeck LinuxFS. Nothing
#  outside it is touched except two idempotently-edited files:
#  * /usr/local/bin/droiddeck-steam-install (the update hook, only through a
#    marked block; see install_steam_install_hook)
#  * /usr/local/.droiddeck-staged — one line is refreshed so DroidDeck's
#    "did anything change under /usr/local?" check keeps accepting the hooked
#    script instead of re-extracting the original from the APK on every session
#    (see refresh_staged_manifest).
# ============================================================================
set -uo pipefail

REPO_SLUG="${LUA_TOOLS_REPO:-DaniloSkyrim/luatools-aarch64}"
SLS_RELEASE_URL="${SLS_RELEASE_URL:-https://github.com/$REPO_SLUG/releases/download/slsteam-arm64/slsteam-arm64.zip}"
LUMEN_RELEASE_URL="${LUMEN_RELEASE_URL:-https://github.com/$REPO_SLUG/releases/download/slsteam-arm64/lumen-arm64.zip}"
PLUGIN_ZIP_URL="${PLUGIN_ZIP_URL:-https://github.com/swwayps/luatools-moon/releases/latest/download/luatools-linux.zip}"
SEVENZIP_URL="${SEVENZIP_URL:-https://github.com/ip7z/7zip/releases/download/26.05/7z2605-linux-arm64.tar.xz}"
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/$REPO_SLUG/main/install.sh}"

OPT_UNINSTALL=0

SHARE="$HOME/.local/share"
STEAM_ROOT="${STEAM_ROOT:-$SHARE/Steam}"
STEAMRT="$STEAM_ROOT/steamrtarm64"
STEAM_BIN="$STEAMRT/steam"
STEAM_REAL="$STEAMRT/steam.real"
SLS_DIR="$SHARE/SLSsteam"
LUMEN_DIR="$SHARE/Lumen"
PLUGIN_DIR="$LUMEN_DIR/luatools"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/SLSsteam"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
WRAPPER_SRC="$SLS_DIR/steam-wrapper"
APPLY_WRAP="$SLS_DIR/apply-wrap.sh"
STEAM_INSTALL="${DROIDDECK_STEAM_INSTALL:-/usr/local/bin/droiddeck-steam-install}"
STEAM_X64_LAUNCHER="${DROIDDECK_STEAM_X64:-/usr/local/bin/droiddeck-steam-x64}"
MARK_BEGIN="# >>> LUATOOLS-AARCH64"
MARK_END="# <<< LUATOOLS-AARCH64"
# DroidDeck re-extracts every file listed in this manifest whose size or mtime
# no longer match what the APK shipped, which silently reverts the hook. The
# manifest records "size mtime_ms"; refresh_staged_manifest rewrites our file's
# line to the patched reality.
STAGED_MANIFEST="${DROIDDECK_STAGED:-/usr/local/.droiddeck-staged}"
LEGACY_HOME="$HOME/.droiddeck-x64"

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
# Only the scratch directory this installer created itself is removed. TMP is
# often inherited (tests export it; some environments point it at /tmp), and
# deleting a directory we did not create is never acceptable.
TMP_CREATED=""
cleanup() { [ -n "$TMP_CREATED" ] && rm -rf "$TMP_CREATED"; }
trap cleanup EXIT

ensure_tmp() {
	if [ -z "$TMP" ]; then
		# A failed mktemp must abort: an empty TMP would turn every scratch path
		# into a root-level one ("/hook-block").
		TMP=$(mktemp -d) || die "could not create a temporary directory"
		[ -n "$TMP" ] && [ -d "$TMP" ] || die "could not create a temporary directory"
		TMP_CREATED=$TMP
	fi
}

usage() {
	cat <<'EOF'
luatools-aarch64 installer for DroidDeck (native aarch64 Steam client)

  --uninstall    remove the launcher wrapper, SLSsteam and Lumen
                 (the LuaTools settings are moved to a backup first)
  --help         this text

Environment:
  LUA_TOOLS_REPO=owner/repo   repository serving the release assets
  SLS_RELEASE_URL=<url>       explicit slsteam-arm64.zip URL
  LUMEN_RELEASE_URL=<url>     explicit lumen-arm64.zip URL
  PLUGIN_ZIP_URL=<url>        explicit luatools-linux.zip URL
EOF
}

parse_args() {
	for a in "$@"; do
		case "$a" in
			--uninstall) OPT_UNINSTALL=1 ;;
			--help|-h) usage; exit 0 ;;
			# Accepted for compatibility with Lumen's Update All button.
			--slsteam-channel|--plugin-channel|--lumen-channel|--nolaunch) : ;;
			stable|beta|--noplugin) : ;;
			*) die "unknown option: $a (see --help)" ;;
		esac
	done
}

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
# Print the ELF machine of a file as aarch64 / x86-64 / i386, or nothing when
# the file is not ELF64. Reads the header directly: the LinuxFS images do not
# always ship file(1), and this is the only thing the installer needs from it.
elf_arch() {
	local f="$1" magic machine
	[ -f "$f" ] || return 1
	magic=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n') || return 1
	[ "$magic" = "7f454c46" ] || return 1
	machine=$(od -An -tx1 -j18 -N2 "$f" 2>/dev/null | tr -d ' \n')
	case "$machine" in
		b700) printf 'aarch64' ;;
		3e00) printf 'x86-64' ;;
		0300) printf 'i386' ;;
		*) printf 'unknown' ;;
	esac
}

fetch() {
	local url="$1" out="$2"
	case "$url" in
		file://*) cp -f "${url#file://}" "$out" ;;
		*) curl -fL --retry 3 --connect-timeout 20 --max-time 900 -o "$out" "$url" ;;
	esac
}

# Verify a download against an optional "<url>.sha256" sidecar. A missing
# sidecar is accepted (older/self-hosted mirrors); a mismatch is fatal.
fetch_verified() {
	local url="$1" out="$2" sum_url="$1.sha256" sum_file expected actual
	fetch "$url" "$out" || return 1
	# ensure_deps only warns when sha256sum is missing; without it there is
	# nothing to compare against, so skip verification instead of treating an
	# empty digest as a mismatch and aborting the whole install.
	if have sha256sum && fetch "$sum_url" "$out.sha256" 2>/dev/null; then
		expected=$(awk '{ print $1; exit }' "$out.sha256" 2>/dev/null)
		rm -f "$out.sha256"
		if [ -n "$expected" ]; then
			actual=$(sha256sum "$out" | awk '{ print $1 }')
			[ "$actual" = "$expected" ] || {
				warn "checksum mismatch for $(basename "$out")"
				rm -f "$out"
				return 1
			}
		fi
	fi
	return 0
}

# Running as real root (adb + su inside the DroidDeck LinuxFS) would leave the
# payload owned by root while the Steam client runs as the Android app's uid,
# which cannot even open Lumen's log. Everything the client touches must carry
# the same ownership as $HOME, which the app created as its own uid — so when
# $HOME is NOT root-owned and we are root, adopt that owner.
fix_ownership() {
	[ "$(id -u)" = "0" ] || return 0
	local owner
	owner=$(stat -c '%u:%g' "$HOME" 2>/dev/null) || return 0
	[ "$owner" = "0:0" ] && return 0
	local dir
	for dir in "$SLS_DIR" "$LUMEN_DIR" "$CONFIG_DIR" "$STEAMRT"; do
		[ -e "$dir" ] && chown -R "$owner" "$dir" 2>/dev/null
	done
	return 0
}

# ----------------------------------------------------------------------------
# environment detection
# ----------------------------------------------------------------------------
detect() {
	local arch
	arch="$(uname -m)"
	[ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ] || \
		die "this installer targets aarch64 (got $arch). Run it inside the DroidDeck desktop."

	[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set"

	if [ ! -f "$STEAMRT/steamclient.so" ]; then
		warn "the native aarch64 Steam client is not present yet"
		if have droiddeck-steam-install; then
			step "asking DroidDeck to download its aarch64 client"
			droiddeck-steam-install || warn "droiddeck-steam-install failed; continuing"
		fi
	fi

	[ -f "$STEAMRT/steamclient.so" ] || die \
"the aarch64 Steam client was not found in $STEAMRT.

  1. Open DroidDeck and let it start Steam once (it downloads steamrtarm64).
  2. Run this installer again inside the DroidDeck desktop."

	[ -f "$STEAM_BIN" ] || [ -f "$STEAM_REAL" ] || die \
"no Steam launcher in $STEAMRT (expected steam or steam.real)."

	ok "host aarch64, native Steam client found"
}

ensure_deps() {
	local missing=() p
	for p in curl unzip tar od awk; do
		have "$p" || missing+=("$p")
	done
	[ "${#missing[@]}" -eq 0 ] || die "missing required tools: ${missing[*]}"
	have sha256sum || warn "sha256sum is missing; release checksums are not verified. \
A corrupted download would be unpacked and installed."
	ok "required tools present"
}

# ----------------------------------------------------------------------------
# SLSsteam aarch64
# ----------------------------------------------------------------------------
install_slsteam() {
	ensure_tmp
	local zip="$TMP/slsteam-arm64.zip" root="$TMP/slsteam" so
	step "downloading SLSsteam aarch64"
	fetch_verified "$SLS_RELEASE_URL" "$zip" || die \
"no prebuilt SLSsteam aarch64 at $SLS_RELEASE_URL.

  Publish the release asset once (see docs/INSTALL.md) or pass
  SLS_RELEASE_URL=<url> pointing at slsteam-arm64.zip."

	mkdir -p "$root"
	unzip -qo "$zip" -d "$root" || die "could not unpack $zip"
	so="$(find "$root" -maxdepth 3 -type f -name SLSsteam.so | head -n1)"
	[ -n "$so" ] || die "the release archive has no SLSsteam.so"
	[ "$(elf_arch "$so")" = "aarch64" ] || die \
"$so is not an aarch64 ELF ($(elf_arch "$so" 2>/dev/null || echo not-elf)).

  The release asset must be the native aarch64 build; the x86-64 one cannot be
  injected into the native client."

	mkdir -p "$SLS_DIR/res"
	install -m 0755 "$so" "$SLS_DIR/SLSsteam.so"
	local cfg
	cfg="$(find "$root" -maxdepth 3 -type f -name config.yaml | head -n1)"
	[ -n "$cfg" ] && install -m 0644 "$cfg" "$SLS_DIR/res/config.yaml"
	# dev builds ship library-inject.so as an empty placeholder; keep it out of
	# LD_AUDIT when it is not a real library.
	rm -f "$SLS_DIR/library-inject.so"
	ok "SLSsteam aarch64 installed in $SLS_DIR"

	seed_config
	install_slsteam_shims
}

# Lumen and the LuaTools plugin read $HOME/.config/SLSsteam/config.yaml. Seed it
# from the previously installed x86-64 setup when it exists, so appids, fake
# ids and tokens survive the move to the native client.
seed_config() {
	mkdir -p "$CONFIG_DIR"
	[ -f "$CONFIG_FILE" ] && return 0
	local legacy="$LEGACY_HOME/.config/SLSsteam/config.yaml"
	if [ -f "$legacy" ]; then
		install -m 0644 "$legacy" "$CONFIG_FILE" && \
			ok "existing SLSsteam settings migrated to $CONFIG_FILE"
		return 0
	fi
	[ -f "$SLS_DIR/res/config.yaml" ] && \
		install -m 0644 "$SLS_DIR/res/config.yaml" "$CONFIG_FILE"
}

# Lumen expects two helpers under ~/.local/share/SLSsteam:
#   * path/steam — the launcher its Restart Steam button executes. It must be
#     the wrapper, otherwise a restart would drop the injection.
#   * ensure-desktop-coverage.sh — called by deskcover; a successful no-op here
#     because the wrapper covers desktop and Game Mode alike.
install_slsteam_shims() {
	mkdir -p "$SLS_DIR/path"
	cat > "$SLS_DIR/path/steam" <<'EOF'
#!/bin/sh
# LuaTools aarch64: restart through the wrapped Steam Runtime launcher so
# SLSsteam and Lumen come back with the client.
root="${XDG_DATA_HOME:-${HOME:-/root}/.local/share}/Steam"
for candidate in "$root/steamrtarm64/steam" "$HOME/.steam/steam/steamrtarm64/steam"; do
	[ -x "$candidate" ] && exec "$candidate" "$@"
done
echo "LuaTools: no aarch64 Steam launcher found" >&2
exit 127
EOF
	chmod 0755 "$SLS_DIR/path/steam"
	printf '#!/bin/sh\n# Desktop coverage is handled by the Steam launcher wrapper.\nexit 0\n' \
		> "$SLS_DIR/ensure-desktop-coverage.sh"
	chmod 0755 "$SLS_DIR/ensure-desktop-coverage.sh"
	ok "SLSsteam launcher shims installed"
}

# ----------------------------------------------------------------------------
# Lumen (aarch64)
# ----------------------------------------------------------------------------
install_lumen() {
	ensure_tmp
	local zip="$TMP/lumen-arm64.zip" root="$TMP/lumen" bin
	step "downloading Lumen aarch64"
	fetch_verified "$LUMEN_RELEASE_URL" "$zip" || die \
"no prebuilt Lumen aarch64 at $LUMEN_RELEASE_URL.

  Publish the release asset once (see docs/INSTALL.md) or pass
  LUMEN_RELEASE_URL=<url> pointing at lumen-arm64.zip."

	mkdir -p "$root"
	unzip -qo "$zip" -d "$root" || die "could not unpack $zip"
	bin="$(find "$root" -maxdepth 2 -type f -name lumen | head -n1)"
	[ -n "$bin" ] || die "the Lumen archive has no lumen binary"
	[ "$(elf_arch "$bin")" = "aarch64" ] || die \
"Lumen in the release is not an aarch64 ELF ($(elf_arch "$bin" 2>/dev/null || echo not-elf))"

	mkdir -p "$LUMEN_DIR"
	install -m 0755 "$bin" "$LUMEN_DIR/lumen"
	local lua_src
	lua_src="$(dirname "$bin")/lua"
	[ -d "$lua_src" ] || die "the Lumen archive has no lua/ tree"
	rm -rf "$LUMEN_DIR/lua"
	cp -r "$lua_src" "$LUMEN_DIR/lua"

	patch_lumen_bundle
	ok "Lumen installed in $LUMEN_DIR"
}

# The published asset is already patched for the native client. These edits are
# idempotent fallbacks for a vanilla Lumen build: Update All must re-run this
# installer (not the upstream 32-bit one), and the helpers must recognise the
# client running as steam.real behind the wrapper.
patch_lumen_bundle() {
	local about="$LUMEN_DIR/lua/about.lua"
	local loop="$LUMEN_DIR/lua/loop.lua"
	local proc="$LUMEN_DIR/lua/proc.lua"
	local slscheck="$LUMEN_DIR/lua/slscheck.lua"
	local restart="$LUMEN_DIR/lua/restart_steam.sh"

	if [ -f "$about" ] && ! grep -q 'LUA_TOOLS-AARCH64-INSTALLER' "$about"; then
		replace_installer_url "$about"
	fi
	# The liveness probe lives in loop.lua (proc.lua is the generic scanner), so
	# either file knowing steam.real is enough.
	if [ -f "$loop" ] || [ -f "$proc" ]; then
		if ! grep -qs 'steam\.real' "$loop" "$proc"; then
			warn "Lumen does not know steam.real; the UI may detach after a restart"
		fi
	fi
	if [ -f "$slscheck" ] && ! grep -q 'STEAM_COMMS' "$slscheck"; then
		warn "Lumen slscheck.lua does not list steam.real; SLSsteam detection may report a miss"
	fi
	# The upstream script matches with pgrep -x '(steam|steam\.real)', so the
	# asset carries the escaped form; accept either spelling.
	if [ -f "$restart" ] && \
		! grep -qF 'steam.real' "$restart" && ! grep -qF 'steam\.real' "$restart"; then
		warn "Lumen restart_steam.sh only matches 'steam'; Restart Steam may refuse to run"
	fi
}

# Point Lumen's Update All at the installer copy kept inside the Lumen dir, so
# it re-applies this stack instead of the upstream i386 one.
replace_installer_url() {
	local f="$1"
	local tmp="$f.luatools-new"
	awk '
		/^about\.INSTALL_URL[[:space:]]*=/ {
			print "-- LUA_TOOLS-AARCH64-INSTALLER: run the local copy of this installer."
			print "about.INSTALL_URL ="
			print "  \"file://\" .. (os.getenv(\"HOME\") or \"\") .. \"/.local/share/Lumen/install.sh\""
			skip = 1
			next
		}
		skip && /^[[:space:]]*"/ { skip = 0; next }
		{ print }
	' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

# ----------------------------------------------------------------------------
# LuaTools plugin + 7zz
# ----------------------------------------------------------------------------
install_sevenzip() {
	mkdir -p "$1/bin"
	ensure_tmp
	local dest="$1/bin/7zz"
	local tmpd="$TMP/7z"
	mkdir -p "$tmpd"
	if fetch "$SEVENZIP_URL" "$TMP/7z.tar.xz" 2>/dev/null && \
		tar -xJf "$TMP/7z.tar.xz" -C "$tmpd" 2>/dev/null; then
		local z
		z="$(find "$tmpd" -maxdepth 3 -type f -name 7zz | head -n1)"
		if [ -n "$z" ] && [ "$(elf_arch "$z")" = "aarch64" ]; then
			# A filesystem without exec bits (or a read-only mount) can make the
			# copy fail; check the file instead of trusting the exit status alone.
			if install -m 0755 "$z" "$dest" 2>/dev/null && [ -s "$dest" ]; then
				ok "aarch64 7zz installed for the plugin backend"
				return 0
			fi
			warn "could not install the downloaded 7zz to $dest"
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
	ensure_tmp
	local zip="$TMP/luatools-linux.zip" root="$TMP/plugin" pj srcdir
	step "downloading the LuaTools plugin"
	fetch "$PLUGIN_ZIP_URL" "$zip" || die "could not download luatools-linux.zip"
	mkdir -p "$root"
	unzip -qo "$zip" -d "$root" || die "could not unpack the LuaTools plugin"
	pj="$(find "$root" -maxdepth 2 -name plugin.json -type f | head -n1)"
	[ -n "$pj" ] || die "the plugin archive has no plugin.json"
	srcdir="$(dirname "$pj")"

	local dest="$PLUGIN_DIR"
	# The plugin keeps its settings and donated appid list under backend/data,
	# and its API credentials in backend/api.json; a reinstall must not reset
	# either. Both are staged outside the tree that gets replaced.
	local data_bak=""
	local api_bak=""
	if [ -d "$dest/backend/data" ] || [ -f "$dest/backend/api.json" ]; then
		data_bak="$LUMEN_DIR/.plugin-data.$$"
		mkdir -p "$data_bak" || die "could not create the plugin backup directory"
		if [ -d "$dest/backend/data" ] && \
			! cp -a "$dest/backend/data/." "$data_bak/" 2>/dev/null; then
			rm -rf "$data_bak"
			die "could not back up the LuaTools settings; reinstall aborted"
		fi
		if [ -f "$dest/backend/api.json" ]; then
			api_bak="$LUMEN_DIR/.plugin-api.$$"
			cp -a "$dest/backend/api.json" "$api_bak" 2>/dev/null || {
				rm -rf "$data_bak" "$api_bak"
				die "could not back up backend/api.json; reinstall aborted"
			}
		fi
	fi

	rm -rf "$dest"
	mkdir -p "$dest"
	# A failed copy (full disk, I/O error) must not leave a half-written plugin
	# tree that looks installed: restore the backup and abort.
	if ! cp -r "$srcdir"/. "$dest"/; then
		rm -rf "$dest"
		if [ -n "$data_bak" ]; then
			mkdir -p "$dest/backend/data"
			cp -a "$data_bak/." "$dest/backend/data/" 2>/dev/null || true
		fi
		[ -z "$api_bak" ] || cp -a "$api_bak" "$dest/backend/api.json" 2>/dev/null || true
		die "could not copy the LuaTools plugin into $dest; the previous install was restored"
	fi

	if [ -n "$data_bak" ]; then
		mkdir -p "$dest/backend/data"
		if cp -a "$data_bak/." "$dest/backend/data/" 2>/dev/null; then
			rm -rf "$data_bak"
			ok "previous LuaTools settings restored"
		else
			warn "could not restore the previous LuaTools settings (kept in $data_bak)"
		fi
	fi
	if [ -n "$api_bak" ]; then
		mkdir -p "$dest/backend"
		if cp -a "$api_bak" "$dest/backend/api.json" 2>/dev/null; then
			rm -f "$api_bak"
			ok "previous LuaTools credentials restored"
		else
			warn "could not restore backend/api.json (kept in $api_bak)"
		fi
	fi

	install_sevenzip "$dest/backend"
	ok "LuaTools plugin installed in $dest"
}

# Move the settings written by the previous x86-64 setup into the native home.
# Only files that do not exist yet are copied, so a running install is never
# overwritten.
migrate_legacy_data() {
	local old_data="$LEGACY_HOME/.local/share/Lumen/luatools/backend/data"
	local new_data="$PLUGIN_DIR/backend/data"
	[ -d "$LEGACY_HOME" ] || return 0

	if [ -d "$old_data" ]; then
		mkdir -p "$new_data"
		if cp -an "$old_data/." "$new_data/" 2>/dev/null; then
			ok "LuaTools settings migrated from $LEGACY_HOME"
		fi
	fi
}

# ----------------------------------------------------------------------------
# Steam launcher wrapper (aarch64)
# ----------------------------------------------------------------------------
write_wrapper() {
	mkdir -p "$SLS_DIR" || die "could not create $SLS_DIR"
	cat > "$WRAPPER_SRC" <<'WRAPPER'
#!/bin/bash
# SLSsteam launcher wrapper (LuaTools aarch64)
# Re-applied after Steam client updates by droiddeck-steam-install.
set -u

SLS_SO="__SLSDIR__/SLSsteam.so"
LUMEN_DIR="__LUMEN_DIR__"

here="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
real="$here/steam.real"
if [ ! -x "$real" ]; then
	echo "SLSsteam: $real is missing, refusing to recurse" >&2
	exit 127
fi

shutdown=0
case " $* " in
	*" -shutdown "*) shutdown=1 ;;
esac

disabled="${SLS_DISABLE:-}"
case "$disabled" in
	''|0|no|false) disabled="" ;;
esac

# Never let an inherited auditor list survive: this script itself sets the only
# one the client should see, and an inherited copy would be loaded twice.
# -f keeps a path like /usr/lib/*/libfoo.so from globbing while we split on ':'.
old_ifs="$IFS"; IFS=:; set -f
clean=""
for a in ${LD_AUDIT:-}; do
	case "$a" in
		''|*SLSsteam.so|*library-inject.so) continue ;;
	esac
	clean="${clean:+$clean:}$a"
done
set +f; IFS="$old_ifs"
if [ -n "$clean" ]; then
	export LD_AUDIT="$clean"
else
	unset LD_AUDIT
fi

if [ "$shutdown" = 0 ] && [ -z "$disabled" ] && [ -d "$LUMEN_DIR" ]; then
	# Lumen attaches over Steam's CEF DevTools endpoint. Steam itself opens the
	# endpoint on port 8080 when this file exists in the Steam ROOT (not in
	# steamrtarm64); droiddeck-session checks the same path and then leaves the
	# port alone instead of passing its own -cef-enable-debugging. Create it in
	# both places: the root is what the launcher and Steam read, the client dir
	# is harmless and covers a manually launched steam.real.
	touch "$here/../.cef-enable-remote-debugging" 2>/dev/null
	touch "$here/.cef-enable-remote-debugging" 2>/dev/null
	[ -d "$HOME/.steam/steam" ] && touch "$HOME/.steam/steam/.cef-enable-remote-debugging" 2>/dev/null

	if [ -x "$LUMEN_DIR/lumen" ] && ! pgrep -f "$LUMEN_DIR/lumen" >/dev/null 2>&1; then
		env -u LD_AUDIT -u LD_PRELOAD -u LD_LIBRARY_PATH \
			-u STEAM_RUNTIME -u STEAM_RUNTIME_LIBRARY_PATH \
			LUMEN_BACKEND_DIR="$LUMEN_DIR/luatools/backend" \
			LUMEN_LUA_DIR="$LUMEN_DIR/lua" \
			LUMEN_SINGLETON_LOCK="$LUMEN_DIR/lumen.lock" \
			setsid "$LUMEN_DIR/lumen" >"$LUMEN_DIR/lumen.log" 2>&1 < /dev/null &
	fi

	# Publish the DevTools port contract Lumen reads (cefport.lua). The owner
	# record (pid + start ticks) makes a contract from a previous session
	# self-invalidating. $$ survives the exec below, so it is the client's pid.
	port="${BL_CDP_PORT:-8080}"
	case "$port" in
		''|*[!0-9]*) port=8080 ;;
	esac
	if [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
		# Field 22 (starttime) of /proc/$$/stat. comm is parenthesised and may
		# itself contain spaces, so count from the LAST field ending in ")".
		start="$(awk '{ last = 0; for (i = 1; i <= NF; i++) if (substr($i, length($i), 1) == ")") last = i; if (last) print $(last + 20) }' "/proc/$$/stat" 2>/dev/null)"
		case "$start" in
			''|*[!0-9]*) start="" ;;
		esac
		if [ -n "$start" ]; then
			printf '%s\nowner %s %s\n' "$port" "$$" "$start" > "$LUMEN_DIR/cef_port.tmp" 2>/dev/null && \
				mv -f "$LUMEN_DIR/cef_port.tmp" "$LUMEN_DIR/cef_port" 2>/dev/null
		else
			printf '%s\n' "$port" > "$LUMEN_DIR/cef_port" 2>/dev/null
		fi
	fi
fi

# -shutdown and SLS_DISABLE=1 both mean "no injection this run"; the client has
# to come up exactly as Valve shipped it.
if [ "$shutdown" = 0 ] && [ -f "$SLS_SO" ] && [ -z "$disabled" ]; then
	export LD_AUDIT="$SLS_SO${clean:+:$clean}"
fi

# Desktop launches omit -noverifyfiles. Steam's self-check then sees this
# wrapper in place of the launcher, re-downloads the client and exits with 42.
case " $* " in
	*" -noverifyfiles "*) ;;
	*) set -- "$@" -noverifyfiles ;;
esac

exec "$real" "$@"
WRAPPER
	sed -i "s|__SLSDIR__|$SLS_DIR|g; s|__LUMEN_DIR__|$LUMEN_DIR|g" "$WRAPPER_SRC"
	chmod 0755 "$WRAPPER_SRC" || die "could not chmod the wrapper"
	ok "Steam launcher wrapper written"
}

write_apply_wrap() {
	cat > "$APPLY_WRAP" <<'APPLY'
#!/bin/bash
# Put the SLSsteam wrapper in front of the native aarch64 Steam client.
# Idempotent: an already-wrapped launcher is only refreshed, and a client
# update (which restores Valve's binary) is wrapped again.
set -u

STEAM_BIN="__STEAM_BIN__"
STEAM_REAL="__STEAM_REAL__"
WRAPPER_SRC="__WRAPPER__"

[ -f "$WRAPPER_SRC" ] || { echo "SLSsteam: missing $WRAPPER_SRC" >&2; exit 0; }

is_wrapper() {
	[ -f "$1" ] && head -c 200 "$1" 2>/dev/null | grep -q "SLSsteam launcher wrapper"
}

is_elf() {
	[ -f "$1" ] && [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

# install(1) is not atomic: a client launched mid-copy would exec a half-written
# wrapper. Stage next to the target (same filesystem) and rename, which is.
install_wrapper() {
	local tmp="$STEAM_BIN.luatools-new.$$"
	cp -f "$WRAPPER_SRC" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	chmod 0755 "$tmp" 2>/dev/null
	mv -f "$tmp" "$STEAM_BIN" || { rm -f "$tmp"; return 1; }
}

if is_wrapper "$STEAM_BIN"; then
	# A new installer version may carry a newer wrapper; keep it current.
	if [ -f "$STEAM_REAL" ]; then
		chmod 0755 "$STEAM_REAL" 2>/dev/null
		install_wrapper || {
			echo "SLSsteam: could not refresh the wrapper at $STEAM_BIN" >&2
			exit 1
		}
		exit 0
	fi
	# steam.real gone but steam is still our wrapper: the client was replaced
	# without the Valve launcher ever appearing (a copy that failed midway).
	# Fail loudly but keep the wrapper running the last thing it can: without
	# steam.real nothing works, and destroying the wrapper would leave steam
	# missing entirely. droiddeck-steam-install must re-download the client.
	echo "SLSsteam: $STEAM_BIN is a wrapper but $STEAM_REAL is missing; the client needs reinstalling" >&2
	exit 1
fi

if [ -f "$STEAM_BIN" ]; then
	if ! is_elf "$STEAM_BIN"; then
		echo "SLSsteam: $STEAM_BIN is neither our wrapper nor an ELF; refusing to replace it" >&2
		exit 1
	fi
	mv -f "$STEAM_BIN" "$STEAM_REAL" || exit 1
fi

# The client is executable in a normal install; restore the bit anyway, since a
# copy that lost it would make the wrapper look broken. A filesystem that cannot
# hold the bit (or a test fixture) only warns: the wrapper reports it at launch.
[ -f "$STEAM_REAL" ] || { echo "SLSsteam: $STEAM_REAL is missing" >&2; exit 1; }
chmod 0755 "$STEAM_REAL" 2>/dev/null
[ -x "$STEAM_REAL" ] || echo "SLSsteam: warning: $STEAM_REAL is not executable" >&2
install_wrapper || { echo "SLSsteam: could not install the wrapper at $STEAM_BIN" >&2; exit 1; }
echo "SLSsteam: wrapper applied to $STEAM_BIN"
APPLY
	sed -i "s|__STEAM_BIN__|$STEAM_BIN|g; s|__STEAM_REAL__|$STEAM_REAL|g; s|__WRAPPER__|$WRAPPER_SRC|g" "$APPLY_WRAP"
	chmod 0755 "$APPLY_WRAP" || die "could not chmod apply-wrap.sh"
}

install_launcher_wrapper() {
	write_wrapper
	write_apply_wrap
	"$APPLY_WRAP" || die "could not wrap the Steam launcher"
	[ -f "$STEAM_REAL" ] || die "$STEAM_REAL is missing after apply-wrap"
	[ "$(elf_arch "$STEAM_REAL")" = "aarch64" ] || die \
"$STEAM_REAL is not an aarch64 ELF; the native client was not found"
	ok "Steam launcher wrapped: $STEAM_BIN -> steam.real"
	install_steam_install_hook
}

# DroidDeck stages /usr/local from its APK and re-extracts any file whose size
# or mtime drifts from usr/local/.droiddeck-staged (lines are
# "<path>\t<size> <mtime_ms> <flag>"). Our hook edits droiddeck-steam-install,
# so without this the hook is silently reverted on the next session start.
# Rewriting the file's line keeps the app's check green without touching the
# APK or anything else in the manifest.
refresh_staged_manifest() {
	local f="$STEAM_INSTALL"
	[ -f "$STAGED_MANIFEST" ] && [ -f "$f" ] || return 0
	# Manifest keys are in-guest paths without the leading slash, e.g.
	# "usr/local/bin/droiddeck-steam-install". DROIDDECK_STAGED_PREFIX lets the
	# tests mount the same layout elsewhere; anything else outside the prefix
	# has no manifest entry to refresh.
	local key prefix="${DROIDDECK_STAGED_PREFIX:-/}"
	# Normalize: "" or "/" both mean "keys are full in-guest paths".
	[ "$prefix" = "/" ] && prefix=""
	case $f in
		"$prefix"/*) key="${f#"$prefix"/}" ;;
		*) return 0 ;;
	esac
	grep -q "^$key	" "$STAGED_MANIFEST" 2>/dev/null || return 0
	local size ms tmp
	size=$(wc -c < "$f") || return 0
	# The app stamps the manifest with millisecond mtimes; mirror that format.
	ms=$(stat -c '%Y' "$f")000
	tmp="$STAGED_MANIFEST.luatools-new"
	# Field 2 (tab-separated) is "size mtime flag" — the flag must survive, or
	# the app treats the entry as malformed and re-extracts the file. Field 3
	# stays whatever it was (the real manifest leaves it empty).
	awk -v key="$key" -v size="$size" -v ms="$ms" '
		BEGIN { FS = "\t"; OFS = "\t" }
		$1 == key {
			n = split($2, p, " ")
			$2 = size " " ms (n >= 3 ? " " p[3] : "")
			done = 1
		}
		{ print }
		END { exit done ? 0 : 1 }
	' "$STAGED_MANIFEST" > "$tmp" || { rm -f "$tmp"; return 0; }
	# The app owns this manifest; keep its ownership when we are root.
	chown --reference="$STAGED_MANIFEST" "$tmp" 2>/dev/null || true
	chmod --reference="$STAGED_MANIFEST" "$tmp" 2>/dev/null || true
	if mv -f "$tmp" "$STAGED_MANIFEST"; then
		ok "droiddeck-staged updated; the hook survives DroidDeck's re-extraction"
	else
		rm -f "$tmp"
		warn "could not refresh .droiddeck-staged; DroidDeck may revert the hook"
	fi
}

# Hook droiddeck-steam-install at two points:
#   * before its early exit — this is the one that matters on every session
#     start. The client self-update (or a repair) restores Valve's ELF behind
#     the wrapper and still leaves the installed stamp, so the script would
#     exit before reaching any hook placed at the bottom; the wrapper would
#     never come back. apply-wrap.sh is a no-op when the launcher is already
#     the wrapper, so running it unconditionally here is cheap.
#   * after the chmod of a freshly downloaded client — covers the reinstall
#     path where the early exit does not trigger.
# It runs at the start of every session and after every client update, so the
# wrapper is re-applied without systemd (the DroidDeck guest has no user
# services).
EARLY_EXIT='[ -z "$sync" ] && [ -x "$steam_root/steamrtarm64/steam" ] && [ -f "$stamp" ] && exit 0'

install_steam_install_hook() {
	local f="$STEAM_INSTALL"
	[ -f "$f" ] || { warn "$f not found; the wrapper is only re-applied by this installer"; return 0; }
	# The rewrite stages a sibling temp file and renames it, so the directory
	# must be writable, not just the file.
	[ -w "$f" ] && [ -w "$(dirname "$f")" ] || {
		warn "$f is not writable; skipping the update hook"
		return 0
	}

	ensure_tmp
	local block="$TMP/hook-block"
	cat > "$block" <<EOF
$MARK_BEGIN
# Re-apply the SLSsteam wrapper after the client was (re)installed.
if [ -x "\$HOME/.local/share/SLSsteam/apply-wrap.sh" ]; then
  "\$HOME/.local/share/SLSsteam/apply-wrap.sh" || true
fi
$MARK_END
EOF
	# A failed block write (full disk) must not let the awk below splice an
	# empty block and still report the hook as installed.
	[ -s "$block" ] || { warn "could not write the hook block; skipping the update hook"; return 0; }

	local anchor='chmod +x "$steam_root/steamrtarm64/steam" 2>/dev/null || true'
	local tmp="$f.luatools-new"
	# Two splices in one pass, each idempotent. The session-start block sits
	# BEFORE the early exit (so it runs on every session start even when the
	# client is already installed): it is already there when the line before
	# the early exit is our MARK_END. The reinstall block sits after the client
	# chmod: already there when the line after it is our MARK_BEGIN. At least
	# one anchor must match exactly; a near-miss would splice the block in the
	# wrong place.
	local prev next already_early already_anchor
	prev=$(awk -v early="$EARLY_EXIT" '
		$0 == early { print save; exit }
		{ save = $0 }
	' "$f")
	case $prev in
		"$MARK_END") already_early=1 ;;
		*) already_early=0 ;;
	esac
	next=$(awk -v anchor="$anchor" '
		found && !printed { print; printed = 1; exit }
		$0 == anchor { found = 1; save = $0 }
	' "$f")
	case $next in
		"$MARK_BEGIN"*) already_anchor=1 ;;
		*) already_anchor=0 ;;
	esac
	awk -v anchor="$anchor" -v early="$EARLY_EXIT" -v block="$block" \
		-v want_early=$((1 - already_early)) -v want_anchor=$((1 - already_anchor)) '
		$0 == early && want_early {
			while ((getline line < block) > 0) print line
			close(block); done_early = 1
		}
		{ print }
		$0 == anchor && want_anchor {
			while ((getline line < block) > 0) print line
			close(block); done_anchor = 1
		}
		END { exit (done_early || done_anchor || !want_early || !want_anchor) ? 0 : 1 }
	' "$f" > "$tmp" || { rm -f "$tmp"; warn "could not hook $f (anchors not found)"; return 0; }

	# Anything after this point only runs when the file changed.
	if cmp -s "$f" "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		ok "droiddeck-steam-install already hooked"
		refresh_staged_manifest
		return 0
	fi
	# Keep the original mode (a session bootstrap must stay executable) and swap
	# atomically: an interrupted rewrite must never leave a truncated script.
	# The session runs as the app's uid, so the hook must keep that owner too —
	# when we are root the new file would be root-owned and the session could
	# not even execute it.
	chown --reference="$f" "$tmp" 2>/dev/null || true
	chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0755 "$tmp"
	if mv -f "$tmp" "$f"; then
		ok "droiddeck-steam-install re-applies the wrapper at session start and after client updates"
		refresh_staged_manifest
	else
		rm -f "$tmp"
		warn "could not hook $f"
	fi
}

uninstall_steam_install_hook() {
	local f="$STEAM_INSTALL"
	[ -f "$f" ] || return 0
	grep -qF "$MARK_BEGIN" "$f" || return 0
	awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
		index($0, b) == 1 { skip = 1; next }
		skip { if (index($0, e) == 1) skip = 0; next }
		{ print }
	' "$f" > "$f.luatools-new" || { rm -f "$f.luatools-new"; return 0; }
	# Keep the original mode (the script must stay executable) and swap atomically.
	chown --reference="$f" "$f.luatools-new" 2>/dev/null || true
	chmod --reference="$f" "$f.luatools-new" 2>/dev/null || chmod 0755 "$f.luatools-new"
	if mv -f "$f.luatools-new" "$f"; then
		ok "droiddeck-steam-install hook removed"
		refresh_staged_manifest
	else
		rm -f "$f.luatools-new"
	fi
}

# The previous x86-64 setup patched droiddeck-steam-x64 to start Lumen and
# inject the FEX guest. That path is not used by the aarch64 client; restore the
# original launcher so two Lumens cannot compete.
cleanup_x86_launcher() {
	local f="$STEAM_X64_LAUNCHER"
	local orig="$f.luatools-orig"
	[ -f "$f" ] || return 0
	if [ -f "$orig" ]; then
		cp -p "$orig" "$f" && rm -f "$orig" && ok "x86-64 launcher restored"
		return 0
	fi
	grep -q 'SLSSTEAM-X64-INJECT' "$f" 2>/dev/null || return 0
	awk '
		/^# >>> SLSSTEAM-X64-INJECT/ { skip = 1; next }
		skip { if ($0 ~ /^# <<< SLSSTEAM-X64-INJECT/) skip = 0; next }
		{ print }
	' "$f" > "$f.luatools-new" || { rm -f "$f.luatools-new"; return 0; }
	# Keep the original mode and swap atomically, as with the update hook.
	chmod --reference="$f" "$f.luatools-new" 2>/dev/null || chmod 0755 "$f.luatools-new"
	if mv -f "$f.luatools-new" "$f"; then
		ok "x86-64 launcher patch removed"
	else
		rm -f "$f.luatools-new"
	fi
}

# Keep a copy of this installer where Lumen's Update All / auto-fix expect it.
install_installer_copy() {
	mkdir -p "$LUMEN_DIR"
	if fetch "$INSTALLER_URL" "$LUMEN_DIR/install.sh" 2>/dev/null; then
		chmod 0755 "$LUMEN_DIR/install.sh"
		ok "installer copy kept in $LUMEN_DIR/install.sh"
	else
		warn "could not refresh $LUMEN_DIR/install.sh; Lumen's Update All may be stale"
	fi
}

# ----------------------------------------------------------------------------
# verification
# ----------------------------------------------------------------------------
verify() {
	local bad=0
	if [ "$(elf_arch "$SLS_DIR/SLSsteam.so")" = "aarch64" ]; then
		ok "SLSsteam.so is aarch64"
	else
		warn "SLSsteam.so has the wrong architecture"; bad=1
	fi
	if [ "$(elf_arch "$LUMEN_DIR/lumen")" = "aarch64" ]; then
		ok "lumen is aarch64"
	else
		warn "lumen has the wrong architecture"; bad=1
	fi
	[ -f "$PLUGIN_DIR/plugin.json" ] && ok "LuaTools plugin present" || { warn "LuaTools plugin missing"; bad=1; }
	grep -qF "SLSsteam launcher wrapper" "$STEAM_BIN" 2>/dev/null && \
		ok "Steam launcher is the SLSsteam wrapper" || { warn "Steam launcher is not wrapped"; bad=1; }
	[ "$(elf_arch "$STEAM_REAL")" = "aarch64" ] && \
		ok "steam.real is the native client" || { warn "steam.real missing or wrong arch"; bad=1; }
	grep -qF 'LD_AUDIT="$SLS_SO' "$STEAM_BIN" 2>/dev/null && \
		ok "wrapper injects SLSsteam through LD_AUDIT" || { warn "wrapper does not set LD_AUDIT"; bad=1; }
	grep -qF -- '-noverifyfiles' "$STEAM_BIN" 2>/dev/null && \
		ok "wrapper passes -noverifyfiles" || { warn "wrapper omits -noverifyfiles"; bad=1; }
	grep -qF "$MARK_BEGIN" "$STEAM_INSTALL" 2>/dev/null && \
		ok "droiddeck-steam-install re-applies the wrapper" || \
		warn "update hook absent; re-run this installer after a Steam client update"
	[ -x "$SLS_DIR/path/steam" ] && ok "Lumen Restart Steam shim present" || { warn "restart shim missing"; bad=1; }
	return "$bad"
}

# ----------------------------------------------------------------------------
# uninstall
# ----------------------------------------------------------------------------
do_uninstall() {
	step "restoring the Steam launcher"
	uninstall_steam_install_hook
	# Only restore when the client is provably our wrapper: swapping a foreign
	# 'steam' (a Valve update mid-flight, another launcher) against steam.real
	# would destroy one of the two. Valve's ELF is always safe to keep.
	if [ -f "$STEAM_REAL" ] && grep -qF "SLSsteam launcher wrapper" "$STEAM_BIN" 2>/dev/null; then
		mv -f "$STEAM_REAL" "$STEAM_BIN" && ok "steam.real restored as steam"
	elif [ -f "$STEAM_REAL" ] && [ ! -f "$STEAM_BIN" ]; then
		mv -f "$STEAM_REAL" "$STEAM_BIN" && ok "steam.real restored as steam"
	elif [ -f "$STEAM_REAL" ]; then
		warn "$STEAM_BIN is not the LuaTools wrapper; leaving both 'steam' and 'steam.real' in place"
	fi

	step "stopping Lumen"
	pkill -f "$LUMEN_DIR/lumen" >/dev/null 2>&1 || true

	# Keep the user's LuaTools settings outside the tree being removed.
	local backup="$SHARE/luatools-data-backup"
	if [ -d "$PLUGIN_DIR/backend/data" ]; then
		mkdir -p "$backup"
		cp -a "$PLUGIN_DIR/backend/data/." "$backup/" 2>/dev/null && \
			ok "LuaTools settings backed up in $backup"
	fi

	step "removing SLSsteam and Lumen"
	rm -rf "$SLS_DIR" "$LUMEN_DIR"
	ok "uninstalled (the Steam client itself was not touched)"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
	parse_args "$@"
	printf '%s\n' "luatools-aarch64 — LuaTools + SLSsteam + Lumen for DroidDeck (native aarch64)"
	if [ "$OPT_UNINSTALL" -eq 1 ]; then
		do_uninstall
		return 0
	fi

	detect
	ensure_deps
	cleanup_x86_launcher
	install_slsteam
	install_lumen
	install_plugin
	migrate_legacy_data
	install_launcher_wrapper
	fix_ownership
	install_installer_copy

	echo
	if verify; then
		cat <<EOF
${B}Instalação concluída.${N}

  Abra a Steam pelo ícone normal do DroidDeck (desktop ou modo jogo).
  O wrapper injeta o SLSsteam no cliente aarch64 e inicia o Lumen.

  Verificação:
    pgrep -af '$LUMEN_DIR/lumen'
    pid=\$(pgrep -x steam.real | head -n1)
    grep -m1 SLSsteam /proc/\$pid/maps
    tail -n 20 \$HOME/.SLSsteam.log

  Log do Lumen: $LUMEN_DIR/lumen.log
  Desativar a injeção numa sessão: SLS_DISABLE=1 (veja o wrapper)
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
