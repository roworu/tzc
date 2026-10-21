# zle layer: menu state, line-pre-redraw, arrow/tab widgets and bindings.

# panel 0 is the completion box, 1 the history box to its right
typeset -gi __tzc_active=0 __tzc_selected=0 __tzc_top=0 __tzc_owns=0
typeset -gi __tzc_panel=0 __tzc_hist_selected=0 __tzc_hist_top=0
typeset -g __tzc_last_key= __tzc_history_moved=0
typeset -gA __tzc_orig_bind

: ${__tzc_max_rows:=${TZC_MAX_ROWS:-10}}
[[ $__tzc_max_rows == <-> ]] || __tzc_max_rows=10
(( __tzc_max_rows < 1 )) && __tzc_max_rows=1
(( __tzc_max_rows > 10 )) && __tzc_max_rows=10

: ${__tzc_max_width:=${TZC_MAX_WIDTH:-80}}
[[ $__tzc_max_width == <-> ]] || __tzc_max_width=80
(( __tzc_max_width < 12 )) && __tzc_max_width=12

__tzc_compute() {
  emulate -L zsh
  __tzc_complete "$BUFFER" "$CURSOR" "$PWD"
  return 0
}

# drop a lone candidate that only repeats the typed word, then reset the
# selection; fails when neither box has anything to show
__tzc_worth_showing() {
  emulate -L zsh
  setopt localoptions noglob
  if (( ${#__tzc_candidates} == 1 )); then
    local -a f
    local IFS=$'\x1f'
    f=( ${=__tzc_candidates[1]} )
    [[ ${f[2]% } == $__tzc_result_typed ]] && __tzc_candidates=()
  fi
  __tzc_selected=0 __tzc_top=0 __tzc_hist_selected=0 __tzc_hist_top=0
  __tzc_panel=$(( ! ${#__tzc_candidates} ))
  (( ${#__tzc_candidates} || ${#__tzc_hist_candidates} ))
}

__tzc_render() {
  emulate -L zsh
  if ! __tzc_render_menu ${#BUFFER} ${(m)#${BUFFER[1,CURSOR]}}; then
    __tzc_hide
    return 0
  fi
  POSTDISPLAY=$__tzc_menu_text
  __tzc_owns=1
  region_highlight=("${(@)region_highlight:#*memo=tzc}")
  region_highlight+=("${(@)__tzc_menu_regions}")
  return 0
}

__tzc_hide() {
  if (( __tzc_owns )); then
    POSTDISPLAY=
    __tzc_owns=0
  fi
  if (( ${#region_highlight} )); then
    region_highlight=("${(@)region_highlight:#*memo=tzc}")
  fi
  __tzc_menu_regions=()
  __tzc_active=0
  return 0
}

# Ctrl-C aborts the line before line-finish runs, so clear the popup from a
# SIGINT handler while zle can still erase its rows.
__tzc_int_cleanup() {
  __tzc_hide
}

__tzc_sigint() {
  emulate -L zsh
  local ret
  if (( ${+functions[__tzc_sigint_saved]} )); then
    __tzc_sigint_saved "$@"
    ret=$?
    (( ret )) || return 0
  else
    ret=$(( 128 + $1 ))
  fi
  (( __tzc_owns )) && zle __tzc_int_cleanup 2>/dev/null
  return $ret
}

__tzc_sigint_install() {
  emulate -L zsh
  # emulate -L enables LOCAL_TRAPS, which would scope the trap to this function
  setopt localoptions no_localtraps
  if (( ${+functions[TRAPINT]} )) &&
     [[ ${functions[TRAPINT]} != "${functions[__tzc_sigint]}" ]]; then
    functions[__tzc_sigint_saved]=${functions[TRAPINT]}
  fi
  functions[TRAPINT]=${functions[__tzc_sigint]}
  return 0
}

__tzc_pre_redraw() {
  # measure before emulating so a prompt using prompt_subst expands the same
  # way zle expanded it
  (( __tzc_prompt_cols < 0 )) && __tzc_measure_prompt
  emulate -L zsh
  if [[ -n ${TZC_DISABLE:-} || -n $PREBUFFER ||
        $KEYMAP == (vicmd|viopp|visual|isearch) ]]; then
    __tzc_hide
    return 0
  fi
  # a finished line can still be redrawn (e.g. while a sourced file runs)
  if [[ $LASTWIDGET == *accept* || $LASTWIDGET == *send-break* ]]; then
    __tzc_hide
    return 0
  fi
  # history moves, zsh's own completion listing and blank input
  if (( __tzc_history_moved )) ||
     [[ $LASTWIDGET == (*history*|*-line-or-search|*complete*|*expand*|menu-select*) ||
        -z ${${BUFFER[1,CURSOR]}//[[:space:]]/} ]]; then
    __tzc_history_moved=0
    __tzc_last_key=
    __tzc_hide
    return 0
  fi
  if (( ${PENDING:-0} > 0 || ${KEYS_QUEUED_COUNT:-0} > 0 )); then
    return 0
  fi
  local key="$PWD:$PATH:$CURSOR:$BUFFER"
  if [[ $key != $__tzc_last_key ]]; then
    __tzc_last_key=$key
    __tzc_compute
    if __tzc_worth_showing; then
      __tzc_active=1
    else
      __tzc_hide
      return 0
    fi
  fi
  (( __tzc_active )) && __tzc_render
  return 0
}

__tzc_accept() {
  emulate -L zsh
  setopt localoptions noglob
  local key="$PWD:$PATH:$CURSOR:$BUFFER"
  if [[ $key != $__tzc_last_key ]]; then
    __tzc_last_key=$key
    __tzc_compute
    __tzc_worth_showing || return 1
  fi
  local -a list f
  local idx
  if (( __tzc_panel )); then
    list=( "${__tzc_hist_candidates[@]}" )
    idx=$(( __tzc_hist_selected + 1 ))
  else
    list=( "${__tzc_candidates[@]}" )
    idx=$(( __tzc_selected + 1 ))
  fi
  (( ${#list} )) || return 1
  (( idx > ${#list} )) && idx=${#list}
  local IFS=$'\x1f'
  f=( ${=list[idx]} )
  local insert=${f[2]}
  [[ -n $insert && $insert != *[[:cntrl:]]* ]] || return 1
  local start=$__tzc_result_start end=$__tzc_result_end
  (( start >= 0 && end >= start && end <= ${#BUFFER} )) || return 1
  if [[ ${f[4]} == history ]]; then
    # a history entry replaces the typed line, not just the current word
    BUFFER="${insert}${BUFFER[end+1,-1]}"
    CURSOR=${#insert}
  else
    BUFFER="${BUFFER[1,start]}${insert}${BUFFER[end+1,-1]}"
    CURSOR=$(( start + ${#insert} ))
  fi
  __tzc_hide
  __tzc_last_key=
  return 0
}

# run the widget the user had bound, falling back to the stock one
__tzc_delegate() {
  emulate -L zsh
  local default=$1 action=$2 binding key
  key="$KEYMAP:$action"
  binding=${__tzc_orig_bind[$key]:-}
  if [[ -n $binding ]] && (( ${+widgets[$binding]} )); then
    zle "$binding"
  else
    zle "$default"
  fi
  return 0
}

# move the selection of the focused box by $1, wrapping at the ends
__tzc_move() {
  emulate -L zsh
  local n
  if (( __tzc_panel )); then
    n=${#__tzc_hist_candidates}
    (( n )) && __tzc_hist_selected=$(( (__tzc_hist_selected + $1 + n) % n ))
  else
    n=${#__tzc_candidates}
    (( n )) && __tzc_selected=$(( (__tzc_selected + $1 + n) % n ))
  fi
  (( n )) || return 0
  __tzc_render
  zle -R
  return 0
}

__tzc_up() {
  emulate -L zsh
  if (( __tzc_active )); then
    __tzc_move -1
  else
    __tzc_history_moved=1
    __tzc_delegate .up-line-or-history up
  fi
  return 0
}

__tzc_down() {
  emulate -L zsh
  if (( __tzc_active )); then
    __tzc_move 1
  else
    __tzc_history_moved=1
    __tzc_delegate .down-line-or-history down
  fi
  return 0
}

# right focuses the history box, left the completion box; otherwise the keys
# keep their own bindings
__tzc_right() {
  emulate -L zsh
  if (( __tzc_active && ! __tzc_panel && ${#__tzc_hist_candidates} )); then
    __tzc_panel=1
    __tzc_render
    zle -R
  else
    __tzc_delegate .forward-char right
  fi
  return 0
}

__tzc_left() {
  emulate -L zsh
  if (( __tzc_active && __tzc_panel && ${#__tzc_candidates} )); then
    __tzc_panel=0
    __tzc_render
    zle -R
  else
    __tzc_delegate .backward-char left
  fi
  return 0
}

__tzc_tab() {
  emulate -L zsh
  if (( __tzc_active )); then
    __tzc_accept || __tzc_hide
    zle -R
  else
    __tzc_delegate .expand-or-complete tab
  fi
  return 0
}

__tzc_save_bind() {
  emulate -L zsh
  local map=$1 action=$2 key=$3 out
  local slot="$map:$action"
  [[ -n ${__tzc_orig_bind[$slot]:-} ]] && return 0
  out=$(bindkey -M $map $key 2>/dev/null) || return 0
  [[ -n $out ]] || return 0
  out=${out##* }
  [[ -n $out && $out != undefined-key && $out != __tzc_* ]] || return 0
  __tzc_orig_bind[$slot]=$out
  return 0
}

__tzc_bind() {
  emulate -L zsh
  local map seq action
  # $KEYMAP is usually "main" with emacs bindings; keep its originals too
  for map in main emacs viins; do
    for seq action in '^[[A' up '^[OA' up '^[[B' down '^[OB' down \
                      '^[[C' right '^[OC' right '^[[D' left '^[OD' left '^I' tab; do
      __tzc_save_bind $map $action $seq
      [[ $map == main ]] || bindkey -M $map $seq __tzc_$action 2>/dev/null
    done
  done
  return 0
}

__tzc_finish() {
  emulate -L zsh
  __tzc_hide
  __tzc_last_key=
  __tzc_history_moved=0
  return 0
}

__tzc_precmd() {
  emulate -L zsh
  __tzc_prompt_cols=-1
  __tzc_hide
  __tzc_last_key=
  return 0
}

__tzc_hook_install() {
  emulate -L zsh
  add-zsh-hook -d precmd __tzc_hook_install
  (( ${+__tzc_hooks} )) && return 0
  add-zle-hook-widget line-pre-redraw __tzc_pre_redraw
  add-zle-hook-widget line-finish __tzc_finish
  typeset -gi __tzc_hooks=1
  return 0
}

__tzc_menu_start() {
  emulate -L zsh
  zle -N __tzc_up
  zle -N __tzc_down
  zle -N __tzc_tab
  zle -N __tzc_left
  zle -N __tzc_right
  zle -N __tzc_int_cleanup
  __tzc_sigint_install
  __tzc_init_render
  __tzc_bind
  if [[ -o zle ]]; then
    __tzc_hook_install
  fi
  add-zsh-hook precmd __tzc_hook_install
  add-zsh-hook precmd __tzc_precmd
  return 0
}
