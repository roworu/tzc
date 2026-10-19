# tzc - Tui Zsh Completions

IDE-like completions for zsh, drawn by shell itself, in any terminal of your choice.
Inspired by fig project: https://github.com/withfig/autocomplete

Up/Down move selection (wrapping at the ends), Tab accepts it, and anything else goes to zsh as usual.
Candidates come from bundled JSON command specs, `PATH` and filesystem.

## Requirements

- zsh 5.9+
- UTF-8 terminal:
  truecolor is used when `COLORTERM` is `truecolor`/`24bit`,otherwise 256 colors
- Python 3:
  for generating new zsh completion specs from JSON file

## Installation

Clone repo

```bash
git clone https://github.com/OWNER/tzc.git --depth 1 ~/.local/share/zsh/tzc
```

Add this to your `~/.zshrc`:

```zsh
source "$HOME/.local/share/zsh/tzc/tzc.zsh"
```

Or whichever path you downloaded plugin to

## Config

You can configure completion popup UI/settings via env options

| variable | meaning |
| --- | --- |
| `TZC_MAX_ROWS` | rows to show, description included, default 10 |
| `TZC_MAX_WIDTH` | width popup may use, default 80 |
| `TZC_NO_COLOR` | use `standout` for the selection instead of colors |
| `TZC_PACKAGES_DIR` | package name cache directory, default `${XDG_CACHE_HOME:-$HOME/.cache}/tzc/packages` |
| `TZC_DISABLE` | do not load the plugin |

### Spec data

To add new completions or change existing, check @completions/README.md

### Package completions

Package arguments of brew, dnf/yum, apt/apt-get/apt-cache, pacman, zypper, apk
and flatpak complete names and descriptions from local caches. Build or refresh
them from the installed package managers' local metadata:

```sh
zsh ~/.local/share/zsh/tzc/completions/tools/package-cache.zsh
```

Managers that are not installed are skipped. dnf reads its metadata cache only;
run `dnf makecache` first if that cache is empty. Cache changes are picked up
automatically.

## Limitations

Will not work with other plugins, utilizing `POSTDISPLAY`, for exmaple `zsh-autosuggestions`

