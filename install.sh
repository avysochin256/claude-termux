#!/usr/bin/env bash
#
# claude-termux — install Claude Code natively on Termux (no proot, no ptrace).
#
#   curl -fsSL https://raw.githubusercontent.com/avyssochin/claude-termux/main/install.sh | bash
#
# What this does, in short:
#   1. installs Termux's glibc package (Claude Code's Linux build is glibc-linked,
#      Termux is bionic-linked, so both libcs have to be present side by side)
#   2. downloads Anthropic's *official* linux-arm64 binary and verifies its
#      published SHA-256 — the binary is never patched or repackaged
#   3. writes a small, readable launcher that starts the binary through the
#      glibc dynamic loader
#
# Everything it installs is plain shell you can read. See README.md for the
# full explanation of why each piece is needed.

set -euo pipefail

# ---------------------------------------------------------------- settings --

VERSION_SPEC="${1:-${CLAUDE_TERMUX_VERSION:-latest}}"   # stable | latest | X.Y.Z

TERMUX_PREFIX=/data/data/com.termux/files/usr
TERMUX_HOME=/data/data/com.termux/files/home
GLIBC="$TERMUX_PREFIX/glibc"
LOADER="$GLIBC/lib/ld-linux-aarch64.so.1"

SHARE="${CLAUDE_TERMUX_HOME:-$TERMUX_HOME/.local/share/claude-termux}"
BINDIR="${CLAUDE_TERMUX_BINDIR:-$TERMUX_PREFIX/bin}"

DOWNLOAD_BASE="${CLAUDE_TERMUX_DOWNLOAD_BASE:-https://downloads.claude.ai/claude-code-releases}"
INSTALLER_URL="${CLAUDE_TERMUX_INSTALLER_URL:-https://raw.githubusercontent.com/avyssochin/claude-termux/main/install.sh}"
PLATFORM=linux-arm64

# Set to 1 to manage Termux packages yourself.
SKIP_PKG="${CLAUDE_TERMUX_SKIP_PKG:-0}"

# ----------------------------------------------------------------- output --

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
    C_B=''; C_G=''; C_Y=''; C_R=''; C_0=''
fi
step() { printf '%s==>%s %s\n' "$C_B$C_G" "$C_0$C_B" "$*$C_0" >&2; }
info() { printf '    %s\n' "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n'   "$C_R" "$C_0" "$*" >&2; exit 1; }

# -------------------------------------------------------------- preflight --

[ -d "$TERMUX_PREFIX" ] || die "this does not look like Termux ($TERMUX_PREFIX is missing)."

case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "unsupported architecture $(uname -m); Claude Code on Termux needs arm64." ;;
esac

command -v curl >/dev/null 2>&1 || SKIP_PKG=0   # we need curl; let the pkg step supply it
[[ "$VERSION_SPEC" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+([^[:space:]]*)?)$ ]] \
    || die "bad version '$VERSION_SPEC' (expected: stable, latest, or X.Y.Z)."

# --------------------------------------------------------------- packages --

if [ "$SKIP_PKG" = 1 ]; then
    step "Skipping Termux package installation (CLAUDE_TERMUX_SKIP_PKG=1)"
else
    step "Installing Termux packages"
    # glibc-repo only adds an apt source; the glibc packages live in it.
    if [ ! -f "$TERMUX_PREFIX/etc/apt/sources.list.d/glibc.list" ]; then
        info "adding the termux-glibc repository"
        pkg install -y glibc-repo >/dev/null || die "could not install glibc-repo."
        apt-get update -qq || true
    fi
    # ripgrep: the launcher sets USE_BUILTIN_RIPGREP=0 so Claude Code uses a
    # bionic-native rg instead of the glibc one bundled in the binary.
    # zstd/jq are optional but make this installer smaller and faster.
    info "installing glibc, ripgrep, git, curl, zstd, jq"
    pkg install -y glibc ripgrep git curl zstd jq >/dev/null \
        || die "package installation failed; run 'pkg update' and try again."
fi

command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
[ -x "$LOADER" ] || die "the glibc loader is still missing at $LOADER."

# ----------------------------------------------------------- pick version --

step "Resolving Claude Code version"
case "$VERSION_SPEC" in
    stable|latest) version="$(curl -fsSL "$DOWNLOAD_BASE/$VERSION_SPEC")" ;;
    *)             version="$VERSION_SPEC" ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
    || die "got '$version' instead of a version number from $DOWNLOAD_BASE."
info "version $version ($PLATFORM)"

manifest="$(curl -fsSL "$DOWNLOAD_BASE/$version/manifest.json")" \
    || die "could not fetch the release manifest for $version."

# Pull one field out of the manifest for our platform. jq when available,
# otherwise a bash regex kept inside the platform's own JSON object ([^{}]*).
manifest_field() {
    local json="$1" field="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg p "$PLATFORM" --arg f "$field" '.platforms[$p][$f] // empty' <<<"$json"
    elif [[ $json =~ \"$PLATFORM\"[[:space:]]*:[[:space:]]*\{[^{}]*\"$field\"[[:space:]]*:[[:space:]]*\"?([A-Za-z0-9]+)\"? ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

checksum="$(manifest_field "$manifest" checksum)"
size="$(manifest_field "$manifest" size)"
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || die "no $PLATFORM checksum in the manifest for $version."

# ---------------------------------------------------------------- binary ---

mkdir -p "$SHARE" "$BINDIR"
binary="$SHARE/claude.exe"

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

if [ -f "$binary" ] && [ "$(sha_of "$binary")" = "$checksum" ]; then
    step "Binary already present and verified — skipping download"
else
    step "Downloading the official binary"
    tmp="$SHARE/.claude.exe.download"
    trap 'rm -f "$tmp" "$tmp.zst"' EXIT
    got=0

    # Prefer the zstd-compressed artifact: same binary, roughly a third of the
    # transfer. Its own checksum lives in a separate manifest.
    if command -v zstd >/dev/null 2>&1 && [[ "$size" =~ ^[1-9][0-9]*$ ]]; then
        zst_manifest="$(curl -fsSL "$DOWNLOAD_BASE/$version/manifest.zst.json" 2>/dev/null || true)"
        zst_checksum="$(manifest_field "$zst_manifest" checksum 2>/dev/null || true)"
        if [[ "$zst_checksum" =~ ^[a-f0-9]{64}$ ]]; then
            info "fetching claude.zst (compressed)"
            if curl -fL --progress-bar "$DOWNLOAD_BASE/$version/$PLATFORM/claude.zst" -o "$tmp.zst" \
               && [ "$(sha_of "$tmp.zst")" = "$zst_checksum" ]; then
                zstd -d -q -c "$tmp.zst" | head -c "$size" > "$tmp" || true
                [ "$(sha_of "$tmp")" = "$checksum" ] && got=1
            fi
            rm -f "$tmp.zst"
        fi
    fi

    if [ "$got" != 1 ]; then
        info "fetching claude (uncompressed, ~$(( ${size:-250000000} / 1000000 )) MB)"
        curl -fL --progress-bar "$DOWNLOAD_BASE/$version/$PLATFORM/claude" -o "$tmp" \
            || die "download failed."
        [ "$(sha_of "$tmp")" = "$checksum" ] || die "SHA-256 mismatch — refusing to install."
    fi

    info "SHA-256 verified: $checksum"
    chmod 755 "$tmp"
    mv -f "$tmp" "$binary"
    trap - EXIT
fi

printf '%s\n' "$version" > "$SHARE/version"

# --------------------------------------------------------------- launcher --

step "Writing the launcher and helpers"

cat > "$BINDIR/claude" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
#
# claude — run Anthropic's official linux-arm64 build of Claude Code directly
# on Termux, on the real Android kernel. No proot, no ptrace, no emulation.
#
# The binary is glibc-linked and its ELF header asks for the interpreter
# /lib/ld-linux-aarch64.so.1. Android has no /lib and / is read-only, so that
# path can never resolve. We therefore skip the kernel's usual lookup and
# invoke the glibc loader ourselves, handing it the binary to run.
#
# The alternative — rewriting the interpreter path with patchelf — does not
# work here: patchelf has to grow the file, and this binary is a Bun
# single-file executable whose payload is located from a trailer at EOF.
# Moving that trailer segfaults the binary. So we never touch the bytes.

set -u

PREFIX=/data/data/com.termux/files/usr
GLIBC="$PREFIX/glibc"
LOADER="$GLIBC/lib/ld-linux-aarch64.so.1"
SHARE="${CLAUDE_TERMUX_HOME:-@SHARE@}"
BIN="$SHARE/claude.exe"

[ -x "$LOADER" ] || { echo "claude: glibc loader missing at $LOADER — run: pkg install glibc" >&2; exit 127; }
[ -f "$BIN" ]    || { echo "claude: binary missing at $BIN — run: claude-update" >&2; exit 127; }

# The glibc process must see Termux's home, not whatever a parent left behind.
export HOME=/data/data/com.termux/files/home
: "${CLAUDE_CONFIG_DIR:=$HOME/.claude}"; export CLAUDE_CONFIG_DIR
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"

# Anything Claude Code spawns has to stay bionic-native, so point it at
# Termux's own bash and ripgrep rather than the glibc copies under $GLIBC/bin.
export USE_BUILTIN_RIPGREP=0
export SHELL="${CLAUDE_SHELL:-$PREFIX/bin/bash}"

# Claude Code's own updater installs a launcher that execs the binary directly,
# which cannot work on Termux. Update with `claude-update` instead.
export DISABLE_AUTOUPDATER=1

# Repair CLAUDE_CODE_EXECPATH inside spawned shells; see the comments in
# claude-shell-prefix. Set CLAUDE_TERMUX_SHELL_FIX=0 to turn this off.
if [ "${CLAUDE_TERMUX_SHELL_FIX:-1}" = 1 ] && [ -x "$SHARE/claude-shell-prefix" ]; then
    export CLAUDE_CODE_SHELL_PREFIX="$SHARE/claude-shell-prefix"
fi

# Termux preloads libtermux-exec.so, a bionic library. Leaving it in the
# environment makes the glibc loader abort before it reaches main().
unset LD_PRELOAD

# Claude Code reaches its bundled ripgrep and bfs by re-running this launcher
# under a different argv[0] (`exec -a ugrep …`, `exec -a bfs …`). The kernel
# throws that argv[0] away for a #! script, so recover it from the mode flag
# and hand it to the loader, which can set argv[0] with --argv0.
argv0=()
case "${1-}" in
    -G) argv0=(--argv0 ugrep) ;;
    -S) argv0=(--argv0 bfs) ;;
esac

exec "$LOADER" --library-path "$GLIBC/lib" "${argv0[@]}" "$BIN" "$@"
LAUNCHER

cat > "$SHARE/claude-shell-prefix" <<'PREFIXFIX'
#!/data/data/com.termux/files/usr/bin/bash
#
# claude-shell-prefix — Claude Code runs every Bash-tool command as:
#
#     claude-shell-prefix '<the entire shell command>'
#
# Why this exists
# ---------------
# Claude Code exports CLAUDE_CODE_EXECPATH=process.execPath into every shell it
# spawns, and the `grep` and `find` shell functions it defines re-exec that
# path to reach its bundled ripgrep and bfs.
#
# Because we start Claude Code *through* the glibc loader, process.execPath is
# /proc/self/exe — the loader, not the binary. Those functions then effectively
# run `ld-linux-aarch64.so.1 -G …`, and the loader reads "-G" as the name of
# the program it should load:
#
#     -G: error while loading shared libraries: -G: cannot open shared object file
#
# so plain `grep` and `find` break inside Claude Code's Bash tool. The variable
# is set by the binary itself, so exporting it from the launcher does not help.
#
# The functions read $CLAUDE_CODE_EXECPATH when they are *called*, though, so
# correcting it here — one level further in, inside the spawned shell — fixes
# them. Set CLAUDE_TERMUX_SHELL_FIX=0 before starting claude to disable this.
export CLAUDE_CODE_EXECPATH=@LAUNCHER@
exec /data/data/com.termux/files/usr/bin/bash -c "$1"
PREFIXFIX

cat > "$BINDIR/claude-update" <<'UPDATER'
#!/data/data/com.termux/files/usr/bin/bash
# claude-update [stable|latest|X.Y.Z] — re-run the installer to fetch and
# verify a newer official binary. Your ~/.claude config is left untouched.
set -euo pipefail
url="${CLAUDE_TERMUX_INSTALLER_URL:-@INSTALLER_URL@}"

# Download to a file first rather than piping into bash: a connection that
# drops halfway would otherwise leave bash executing a truncated script.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! curl -fsSL "$url" -o "$tmp"; then
    echo "claude-update: could not fetch the installer from" >&2
    echo "  $url" >&2
    echo "Set CLAUDE_TERMUX_INSTALLER_URL to point somewhere else; a file:// path works too." >&2
    exit 1
fi
exec bash "$tmp" "${1:-latest}"
UPDATER

cat > "$BINDIR/claude-uninstall" <<'UNINSTALLER'
#!/data/data/com.termux/files/usr/bin/bash
# claude-uninstall — remove the launcher and the downloaded binary.
# Your configuration and history in ~/.claude are deliberately kept; delete
# that directory yourself if you want them gone too.
set -euo pipefail
SHARE="@SHARE@"
BINDIR="@BINDIR@"
rm -rf "$SHARE"
rm -f "$BINDIR/claude" "$BINDIR/claude-update" "$BINDIR/claude-uninstall"
echo "Removed Claude Code. Config kept in ~/.claude (delete it manually if you want)."
echo "The Termux glibc package was left installed; remove it with: pkg uninstall glibc"
UNINSTALLER

# Bake the resolved paths into the scripts we just wrote.
sed -i "s|@SHARE@|$SHARE|g; s|@BINDIR@|$BINDIR|g; s|@LAUNCHER@|$BINDIR/claude|g; s|@INSTALLER_URL@|$INSTALLER_URL|g" \
    "$BINDIR/claude" "$BINDIR/claude-update" "$BINDIR/claude-uninstall" "$SHARE/claude-shell-prefix"
chmod 755 "$BINDIR/claude" "$BINDIR/claude-update" "$BINDIR/claude-uninstall" "$SHARE/claude-shell-prefix"

# ------------------------------------------------------------------ check --

step "Verifying the installation"
reported="$("$BINDIR/claude" --version 2>&1 | head -1)" \
    || die "the launcher could not start the binary: $reported"
info "$reported"

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) warn "$BINDIR is not on your PATH; add it or run $BINDIR/claude directly." ;;
esac

printf '\n%sClaude Code is installed.%s Run %sclaude%s to start, %sclaude-update%s to upgrade.\n\n' \
    "$C_B$C_G" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0" >&2
