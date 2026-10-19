# zle layer: menu state, line-pre-redraw, up/down/tab widgets and bindings.

typeset -gi __tzc_active=0 __tzc_selected=0 __tzc_top=0 __tzc_owns=0
typeset -g __tzc_last_key= __tzc_history_moved=0
typeset -gA __tzc_orig_bind

: ${__tzc_max_rows:=${TZC_MAX_ROWS:-10}}
[[ $__tzc_max_rows == <-> ]] || __tzc_max_rows=10
(( __tzc_max_rows < 1 )) && __tzc_max_rows=1
(( __tzc_max_rows > 10 )) && __tzc_max_rows=10

__tzc_compute() {
  emulate -L zsh
  __tzc_complete "$BUFFER" "$CURSOR" "$PWD"
  return 0
}

__tzc_worth_showing() {
  emulate -L zsh
  setopt localoptions noglob
  local n=${#__tzc_candidates}
  (( n )) || return 1
  if (( n == 1 )); then
    local -a f
    IFS=$'\x1f' f=( ${=__tzc_candidates[1]} )
    local insert=${f[2]}
    insert=${insert% }
    [[ $insert == $__tzc_result_typed ]] && return 1
  fi
  return 0
}

__tzc_render() {
  emulate -L zsh
  if ! __tzc_render_menu ${#BUFFER}; then
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

__tzc_pre_redraw() {
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
  if (( __tzc_history_moved )) ||
     [[ $LASTWIDGET == *history* || $LASTWIDGET == *-line-or-search ]]; then
    __tzc_history_moved=0
    __tzc_last_key=
    __tzc_hide
    return 0
  fi
  # do not fight zsh's own completion listing
  if [[ $LASTWIDGET == *complete* || $LASTWIDGET == *expand* ||
        $LASTWIDGET == menu-select* ]]; then
    __tzc_last_key=
    __tzc_hide
    return 0
  fi
  local before=${BUFFER[1,CURSOR]}
  if [[ -z ${before//[[:space:]]/} ]]; then
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
      __tzc_selected=0
      __tzc_top=0
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
    __tzc_selected=0
    __tzc_top=0
    __tzc_worth_showing || return 1
  fi
  local n=${#__tzc_candidates}
  (( n )) || return 1
  local idx=$(( __tzc_selected + 1 ))
  (( idx > n )) && idx=$n
  local -a f
  IFS=$'\x1f' f=( ${=__tzc_candidates[idx]} )
  local insert=${f[2]}
  [[ -n $insert && $insert != *[[:cntrl:]]* ]] || return 1
  local start=$__tzc_result_start end=$__tzc_result_end
  (( start >= 0 && end >= start && end <= ${#BUFFER} )) || return 1
  BUFFER="${BUFFER[1,start]}${insert}${BUFFER[end+1,-1]}"
  CURSOR=$(( start + ${#insert} ))
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
  if [[ -n $binding && ${+widgets[$binding]} ]]; then
    zle "$binding"
  else
    zle "$default"
  fi
  return 0
}

__tzc_up() {
  emulate -L zsh
  if (( __tzc_active )); then
    (( __tzc_selected > 0 )) && (( __tzc_selected-- ))
    __tzc_render
    zle -R
  else
    __tzc_history_moved=1
    __tzc_delegate .up-line-or-history up
  fi
  return 0
}

__tzc_down() {
  emulate -L zsh
  if (( __tzc_active )); then
    (( __tzc_selected < ${#__tzc_candidates} - 1 )) && (( __tzc_selected++ ))
    __tzc_render
    zle -R
  else
    __tzc_history_moved=1
    __tzc_delegate .down-line-or-history down
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
  local map
  # $KEYMAP is usually "main" with emacs bindings; keep its originals too
  __tzc_save_bind main up '^[[A'
  __tzc_save_bind main up '^[OA'
  __tzc_save_bind main down '^[[B'
  __tzc_save_bind main down '^[OB'
  __tzc_save_bind main tab '^I'
  for map in emacs viins; do
    __tzc_save_bind $map up '^[[A'
    __tzc_save_bind $map up '^[OA'
    __tzc_save_bind $map down '^[[B'
    __tzc_save_bind $map down '^[OB'
    __tzc_save_bind $map tab '^I'
    bindkey -M $map '^[[A' __tzc_up 2>/dev/null
    bindkey -M $map '^[[B' __tzc_down 2>/dev/null
    bindkey -M $map '^[OA' __tzc_up 2>/dev/null
    bindkey -M $map '^[OB' __tzc_down 2>/dev/null
    bindkey -M $map '^I' __tzc_tab 2>/dev/null
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
  __tzc_init_render
  __tzc_bind
  if [[ -o zle ]]; then
    __tzc_hook_install
  fi
  add-zsh-hook precmd __tzc_hook_install
  add-zsh-hook precmd __tzc_precmd
  return 0
}
