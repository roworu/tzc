# completions

JSON command specs and zsh data generated from them.

| path | role |
| --- | --- |
| `json/*.json` | source specs, edit/add these |
| `tools/convert.py` | JSON -> zsh converter |
| `tools/package-cache.zsh` | build package name/description caches from local metadata |
| `compile.zsh` | regenerate and compile the zsh specs |
| `zsh/*.zsh` | generated packed specs |
| `zsh/index.zsh` | generated command -> description map |
| `zsh/*.zwc` | local `zcompile` cache, never commit |

## Adding a completion

Create or edit a spec in `json/`, then regenerate and compile:

```bash
./completions/compile.zsh --regenerate
```

Python 3 is required for that step

## Spec schema

`tools/convert.py` reads this subset of a spec:

- `name` (string or list), `description`, `priority` (0-100), `hidden`
- `options`: same fields plus `isPersistent`, `isRepeatable`, `args`
- `subcommands`: same fields plus nested `options`, `subcommands`, `args`
- `args`: `name`, `description`, `suggestions`, `template`, `isOptional`,
  `isVariadic`; may be a single object or a list
- `suggestions`: strings or `{name, description, priority, hidden}` objects
- `template`: `filepaths`, `folders`, or `packages:<manager>`; other values are
  ignored. `<manager>` names a cache file in `TZC_PACKAGES_DIR` (default
  `${XDG_CACHE_HOME:-$HOME/.cache}/tzc/packages`)

## Package caches

`packages:<manager>` arguments read one package per line from
`$TZC_PACKAGES_DIR/<manager>`, as `name<TAB>description`; a bare name means an
empty description. The plugin never starts a package manager; refresh the
caches explicitly from local metadata:

```sh
zsh tools/package-cache.zsh            # every installed manager
zsh tools/package-cache.zsh dnf apt    # selected managers
```

Managers: `dnf` (also used by yum), `apt` (apt, apt-get, apt-cache), `pacman`,
`zypper`, `apk`, `flatpak`.

## Packed format

Each `<name>.zsh` contains one packed blob:

```zsh
typeset -g __tzc_s_version=1
typeset -g __tzc_s_blob=$'r\x1fgit\x1f...'
typeset -g __tzc_s_ok=1
```

A record:

```text
kind \x1f names \x1f description \x1f priority \x1f flags \x1f template \x1f
suggestions \x1f option-children \x1f subcommand-children \x1f arg-children
```

- records are separated by `\x1e`, fields by `\x1f`
- lists use `\x1d`; suggestion records use `\x1c` and hold
  `names \x1d description \x1d priority \x1d hidden`
- kinds: `r` root, `s` subcommand, `o` option, `a` argument
- flags: `P` persistent, `R` repeatable, `H` hidden, `O` optional, `V` variadic,
  `T` takes a value
- child fields hold 1-based record ids

`.zwc` files are local build artifacts; do not commit them.
