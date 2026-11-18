# tzc - Tui Zsh Completions

IDE-like completions for zsh, drawn by shell itself, in any terminal of your choice.
Inspired by fig project: https://github.com/withfig/autocomplete

Up/Down move selection (wrapping at the ends), Tab accepts it, and anything else goes to zsh as usual.
Candidates come from [compcore](https://github.com/roworu/compcore), a completion engine
that tzc runs once per shell in the background (bundled specs for ~135 commands, `PATH`, the
filesystem, package manager caches and the `--help` of commands without a spec), and from
shell history. tzc only draws them.

## Requirements

- zsh 5.9+
- UTF-8 terminal:
  menu colors come from terminal palette
- `compcore` on `PATH`, or its path in `TZC_COMPCORE`. Without it only history suggestions
  show.

## Installation

Clone repo

```bash
git clone https://github.com/roworu/tzc.git --depth 1 ~/.local/share/zsh/tzc
```

Add this to your `~/.zshrc`:

```zsh
source "$HOME/.local/share/zsh/tzc/tzc.zsh"
```

Or whichever path you downloaded plugin to

Then install compcore, the engine, from its latest release (static binaries for Linux
x86_64/aarch64 and macOS; building it yourself is described in its README):

```bash
target=x86_64-unknown-linux-musl   # aarch64-unknown-linux-musl, aarch64-apple-darwin, x86_64-apple-darwin
mkdir -p ~/.local/bin
curl -fsSL "https://github.com/roworu/compcore/releases/latest/download/compcore-$target.tar.gz" |
  tar -xz -C ~/.local/bin compcore
```

### Update

Pull changes (and download compcore again for a newer release), then restart the shell:

```bash
git -C ~/.local/share/zsh/tzc pull
exec zsh
```

## Config

You can configure completion popup UI/settings via env options

| variable | meaning |
| --- | --- |
| `TZC_MAX_ROWS` | rows to show, description included, default 10 |
| `TZC_MAX_WIDTH` | width popup may use, default 80 |
| `TZC_HISTORY` | recent history entries starting with the typed line, shown above the completions; 0 disables, default 3 |
| `TZC_HISTORY_PWD` | 1 shows only history run in the current directory (recorded this session), default 1; 0 shows all |
| `TZC_COMPCORE` | path of the compcore binary, default the one on `PATH` |
| `TZC_PROBE_HELP` | 0 never runs `<command> --help` for commands without a spec, default 1 |
| `TZC_NO_COLOR` | use `standout` for the selection instead of colors |
| `TZC_DISABLE` | do not load the plugin, or hide the popup if set in a running shell; e.g. `[[ $TERM_PROGRAM == vscode ]] && export TZC_DISABLE=1` before sourcing to skip it in an IDE terminal |

### Spec data

A `<command>.json` (fig-style spec) in `~/.config/tzc/specs/` replaces the bundled spec of that
command; restart the shell after changing one. How specs are written and generated is in
compcore's `docs/COMPLETIONS.md`.

### Package completions

Package arguments of brew, dnf/yum, apt/apt-get/apt-cache, pacman, zypper, apk and flatpak
complete names from the package manager's local cache, read once per shell. dnf reads its
metadata cache only; run `dnf makecache` first if that cache is empty.

## Limitations

Will not work with other plugins, utilizing `POSTDISPLAY`, for exmaple `zsh-autosuggestions`

