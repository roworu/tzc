# tzc: IDE-like completions for zsh
#
# source this file from .zshrc

[[ -o interactive ]] || return 0
zmodload zsh/zle 2>/dev/null || return 0
zmodload zsh/parameter 2>/dev/null
autoload -Uz add-zsh-hook add-zle-hook-widget 2>/dev/null || return 0

(( ${+__tzc_loaded} )) && return 0
typeset -g __tzc_loaded=1
[[ -n ${TZC_DISABLE:-} ]] && return 0

typeset -g __tzc_root=${${(%):-%x}:A:h}
: ${__tzc_specs_dir:=$__tzc_root/completions/zsh}

source "$__tzc_root/lib/spec.zsh"
source "$__tzc_root/lib/engine.zsh"
source "$__tzc_root/lib/render.zsh"
source "$__tzc_root/lib/menu.zsh"

# first source after install: build the caches that used to be manual. spec
# compilation is quick; package managers can be slow, so that part runs
# detached and writes the marker when it finishes.
__tzc_first_run() {
  emulate -L zsh
  local cache=${XDG_CACHE_HOME:-$HOME/.cache}/tzc
  local marker=$cache/installed lock=$cache/setup.lock log=$cache/setup.log
  [[ -f $marker && $(<$marker) == "$__tzc_root" ]] && return 0
  mkdir -p -- "$cache" 2>/dev/null || return 0
  # drop a lock left behind by a killed setup
  local -a stale
  stale=( $lock(Nmh+1) )
  (( ${#stale} )) && rm -rf -- "$lock"
  mkdir -- "$lock" 2>/dev/null || return 0
  print -r -- "tzc: installed successfully; generating completion caches"
  zsh "$__tzc_root/completions/compile.zsh" >"$log" 2>&1 </dev/null
  print -r -- "tzc: building package caches in the background (log: $log)"
  {
    zsh "$__tzc_root/completions/tools/package-cache.zsh"
    print -r -- "$__tzc_root" >"$marker"
    rm -rf -- "$lock"
  } >>"$log" 2>&1 </dev/null &!
  return 0
}

__tzc_engine_init
__tzc_menu_start
__tzc_first_run
