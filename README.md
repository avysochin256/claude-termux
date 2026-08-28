# claude-termux

Run [Claude Code](https://code.claude.com) natively on Termux — on the real
Android kernel, with no `proot`, no `ptrace`, and no emulation. Anthropic's
official binary is installed byte-for-byte as published: **no patching, no
repackaging**, so you can check it against Anthropic's own SHA-256 at any time.

```sh
curl -fsSL https://raw.githubusercontent.com/avysochin256/claude-termux/main/install.sh | bash
```

Then run `claude`.

![Installing Claude Code on Termux](docs/demo.gif)

<sub>A real first install on this repo's own installer — nothing staged. The
70 MiB compressed download is time-compressed in the recording; everything else
plays at the speed it happened. Replay the raw capture with
`asciinema play docs/demo.cast`.</sub>

Anthropic ships an official `linux-arm64` build of Claude Code, and your phone
is an arm64 Linux machine. The only thing standing between them is libc: that
build is linked against **glibc**, and Termux is linked against Android's
**bionic**. Termux packages glibc, so both can live side by side — this repo is
the small amount of glue that makes them meet.

The usual workaround is to install a whole Ubuntu rootfs under `proot-distro`
and run Claude Code inside it. That works, but every syscall goes through
`ptrace`, which is slow, and you end up maintaining a second distribution.
Here the binary runs as an ordinary Android process.

## Requirements

- Termux (from [F-Droid](https://f-droid.org/packages/com.termux/) or GitHub —
  **not** the Play Store build)
- An arm64 device (`uname -m` reports `aarch64`)
- ~700 MB free: ~250 MB for the binary, the rest for glibc and packages

## What gets installed

| Path | What it is |
| --- | --- |
| `$PREFIX/bin/claude` | The launcher — a readable shell script |
| `$PREFIX/bin/claude-update` | Fetches and verifies a newer official binary |
| `$PREFIX/bin/claude-uninstall` | Removes the above; keeps your config |
| `~/.local/share/claude-termux/claude.exe` | Anthropic's official binary, unmodified |
| `~/.local/share/claude-termux/claude-shell-prefix` | Shell fix, explained below |
| `~/.claude/` | Your config, credentials and history (untouched by updates) |

The installer also installs the Termux packages `glibc`, `ripgrep`, `git`,
`curl`, `zstd` and `jq`.

**The binary is never patched.** It is downloaded from Anthropic's own release
server and its published SHA-256 is checked before installation; if the hash
does not match, the installer refuses. Everything else here is shell script you
can read in a couple of minutes.

## How it works

Three things break if you just try to run the binary, and the launcher deals
with each of them.

### 1. The ELF interpreter path does not exist

The binary's header asks the kernel to load `/lib/ld-linux-aarch64.so.1`.
Android has no `/lib`, and `/` is read-only, so that path can never resolve.

Instead of letting the kernel do the lookup, the launcher runs the glibc loader
itself and hands it the binary:

```sh
exec "$GLIBC/lib/ld-linux-aarch64.so.1" --library-path "$GLIBC/lib" "$BIN" "$@"
```

The obvious alternative — rewriting the interpreter path with `patchelf` — does
**not** work here, and this is worth knowing before you try it. Claude Code is a
[Bun](https://bun.sh) single-file executable: its JavaScript payload is found
through a trailer at the very end of the file. `patchelf` has to grow the file
to fit the longer interpreter string, which moves that trailer. The result
still looks like a valid ELF and segfaults immediately. Leaving the bytes alone
also means you can verify the binary against Anthropic's published hash at any
time.

### 2. Termux preloads a bionic library

Termux sets `LD_PRELOAD=…/libtermux-exec.so` so that `#!/bin/sh` shebangs work.
That library is bionic-linked; preloading it into a glibc process aborts the
loader before `main()`. The launcher clears `LD_PRELOAD` for the child.

### 3. `grep` and `find` inside Claude Code's Bash tool

This one is subtle. Claude Code exports `CLAUDE_CODE_EXECPATH=process.execPath`
into every shell it spawns, and defines `grep` and `find` shell functions that
re-exec that path to reach its own bundled ripgrep and `bfs`:

```sh
(exec -a ugrep "$_cc_bin" -G --ignore-files … )
```

Because we start Claude Code *through* the loader, `process.execPath` is
`/proc/self/exe` — the loader, not the binary. So those functions end up running
`ld-linux-aarch64.so.1 -G …`, and the loader reads `-G` as the name of the
program to load:

```
-G: error while loading shared libraries: -G: cannot open shared object file
```

Plain `grep` and `find` then fail for every command Claude Code runs. Exporting
the variable from the launcher does not help — the binary overwrites it.

The fix has two halves:

- Claude Code wraps each Bash-tool command in `$CLAUDE_CODE_SHELL_PREFIX`. The
  launcher points that at `claude-shell-prefix`, which re-exports
  `CLAUDE_CODE_EXECPATH` back to the launcher *inside* the spawned shell. The
  shell functions read the variable when they are called, so this reaches them.
- A `#!` script cannot see the `argv[0]` that `exec -a` sets — the kernel
  replaces it with the script path. The launcher recovers it from the mode flag
  (`-G` → `ugrep`, `-S` → `bfs`) and passes it through with the loader's
  `--argv0`.

With both halves in place, `grep` and `find` work normally inside Claude Code,
routed through its bundled ripgrep and `bfs` exactly as they are on a desktop
Linux install. To confirm it in a running session:

```sh
grep -c DISABLE_AUTOUPDATER ~/claude-termux/install.sh   # prints 1
echo "$CLAUDE_CODE_EXECPATH"    # the launcher, not .../ld-linux-aarch64.so.1
```

There is no ambiguity about which path you are on: if the fix is not active the
first command fails outright with the `-G:` error above rather than quietly
falling back, and `CLAUDE_CODE_EXECPATH` still points at the loader.

One gotcha: the launcher exports the fix at **startup**, so a `claude` session
that was already running when you installed or updated keeps the old, broken
environment. Restart `claude` to pick it up.

Set `CLAUDE_TERMUX_SHELL_FIX=0` to turn this off and leave `grep`/`find` broken.

### Other launcher settings

- `USE_BUILTIN_RIPGREP=0` and `SHELL=$PREFIX/bin/bash` keep spawned processes
  bionic-native, rather than reaching for the glibc copies under `$PREFIX/glibc/bin`.
- `DISABLE_AUTOUPDATER=1`, because Claude Code's own updater installs a launcher
  that execs the binary directly — which cannot work here. Use `claude-update`.

## Updating

```sh
claude-update            # latest
claude-update stable     # the stable channel
claude-update 2.1.247    # a specific version
```

Re-running with a version you already have verifies the existing file and skips
the download.

## Uninstalling

```sh
claude-uninstall         # removes the launcher and binary; keeps ~/.claude
```

## Environment variables

| Variable | Default | Effect |
| --- | --- | --- |
| `CLAUDE_TERMUX_HOME` | `~/.local/share/claude-termux` | Where the binary lives |
| `CLAUDE_TERMUX_BINDIR` | `$PREFIX/bin` | Where the launcher is installed |
| `CLAUDE_TERMUX_SKIP_PKG` | `0` | Set to `1` to manage Termux packages yourself |
| `CLAUDE_TERMUX_SHELL_FIX` | `1` | Set to `0` to disable the `grep`/`find` fix |
| `CLAUDE_SHELL` | `$PREFIX/bin/bash` | Shell Claude Code spawns |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Config and credentials directory |

## Troubleshooting

**`claude: glibc loader missing`** — `pkg install glibc-repo && pkg install glibc`.

**`grep`/`find` fail with `-G: error while loading shared libraries`** — the
shell fix is not active. Check that `~/.local/share/claude-termux/claude-shell-prefix`
exists and is executable, and that `CLAUDE_TERMUX_SHELL_FIX` is not set to `0`.

**A stale `claude` shadows the new one** — `command -v claude` should print
`$PREFIX/bin/claude`. If it prints something under `~/bin`, remove that one.

**Checksum mismatch during install** — a corrupted or intercepted download.
Re-run; it will not install an unverified binary.

## Verifying the binary yourself

```sh
sha256sum ~/.local/share/claude-termux/claude.exe
curl -s https://downloads.claude.ai/claude-code-releases/$(cat ~/.local/share/claude-termux/version)/manifest.json \
  | jq -r '.platforms["linux-arm64"].checksum'
```

The two should match. This repo ships no binaries of its own.
