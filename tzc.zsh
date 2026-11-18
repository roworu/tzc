# tzc: IDE-like completions for zsh
#
# source this file from .zshrc

[[ -o interactive ]] || return 0
zmodload zsh/zle 2>/dev/null || return 0
zmodload zsh/parameter 2>/dev/null
zmodload zsh/system 2>/dev/null || return 0
autoload -Uz add-zsh-hook add-zle-hook-widget 2>/dev/null || return 0

(( ${+__tzc_loaded} )) && return 0
typeset -g __tzc_loaded=1
[[ -n ${TZC_DISABLE:-} ]] && return 0

typeset -g __tzc_root=${${(%):-%x}:A:h}

source "$__tzc_root/lib/engine.zsh"
source "$__tzc_root/lib/render.zsh"
source "$__tzc_root/lib/menu.zsh"

__tzc_engine_start
__tzc_menu_start
