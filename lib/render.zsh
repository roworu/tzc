# build the POSTDISPLAY menu and its region_highlight entries.

typeset -gA __tzc_palette
typeset -g __tzc_color_mode
typeset -g __tzc_menu_text
typeset -ga __tzc_menu_regions
typeset -gi __tzc_menu_rows
typeset -gi __tzc_prompt_cols=-1

__tzc_init_render() {
  emulate -L zsh
  if [[ -n ${TZC_NO_COLOR:-} || -n ${NO_COLOR:-} ]]; then
    __tzc_color_mode=none
  elif [[ ${COLORTERM:-} == (truecolor|24bit) ]]; then
    __tzc_color_mode=true
  else
    __tzc_color_mode=256
  fi
  __tzc_palette=()
  case $__tzc_color_mode in
    (true)
      __tzc_palette=(
        desc 'fg=#a6adc8'
        subcommand 'fg=#cba6f7'
        suggestion 'fg=#89dceb'
        option 'fg=#f9e2af'
        command 'fg=#a6e3a1'
        folder 'fg=#89b4fa'
        file 'fg=#cdd6f4'
      )
      ;;
    (256)
      __tzc_palette=(
        desc 'fg=245'
        subcommand 'fg=141'
        suggestion 'fg=117'
        option 'fg=222'
        command 'fg=114'
        folder 'fg=111'
        file 'fg=252'
      )
      ;;
  esac
  return 0
}

# store the display width of the last prompt line in __tzc_prompt_cols. runs
# with the caller's options so prompt_subst matches the real prompt.
__tzc_measure_prompt() {
  setopt localoptions extendedglob
  local text=${(%%)PROMPT}
  # csi, osc and other escape sequences take no cells; %{...%} output is
  # literal escape text after prompt expansion
  text=${text//$'\e'\[[0-9;:?<=>!#-]#[ -\/]#[@-~]/}
  text=${text//$'\e'\]([^$'\a'$'\e']|$'\e'[^\\])#($'\a'|$'\e'\\)/}
  text=${text//$'\e'[^$'\e']/}
  text=${text##*$'\n'}
  __tzc_prompt_cols=${(m)#text}
  return 0
}

# build __tzc_menu_text and __tzc_menu_regions for the current candidate list.
# $1 is the offset of the leading newline in BUFFER+POSTDISPLAY (i.e. #BUFFER);
# $2 is the display width of BUFFER up to CURSOR.
__tzc_render_menu() {
  emulate -L zsh
  setopt localoptions noglob extendedglob
  local base=$1
  local cursor_col=${2:-0}
  __tzc_menu_text=
  __tzc_menu_regions=()
  __tzc_menu_rows=0
  local total=${#__tzc_candidates}
  (( total )) || return 1

  local columns=${COLUMNS:-80} lines=${LINES:-24}
  (( columns < 1 )) && columns=80
  (( lines < 5 )) && lines=24
  local max_rows=${__tzc_max_rows:-10}
  (( max_rows > lines - 3 )) && max_rows=$(( lines - 3 ))
  (( max_rows < 1 )) && return 1
  local rows=$total
  (( rows > max_rows )) && rows=$max_rows
  local top=${__tzc_top:-0} sel=${__tzc_selected:-0}
  (( sel < 0 )) && sel=0
  (( sel >= total )) && sel=$(( total - 1 ))
  (( top < 0 )) && top=0
  (( top > total - rows )) && top=$(( total - rows ))
  (( sel < top )) && top=$sel
  (( sel >= top + rows )) && top=$(( sel - rows + 1 ))
  __tzc_top=$top
  __tzc_menu_rows=$rows

  # width from every candidate, not just the visible rows, so scrolling does
  # not resize the box under the pointer
  local maxw=0 rec w
  local -a f
  for rec in "${__tzc_candidates[@]}"; do
    IFS=$'\x1f' f=( ${=rec} )
    w=$(( 3 + ${#f[1]} ))
    [[ -n ${f[3]} ]] && w=$(( w + 2 + ${#f[3]} ))
    (( w > maxw )) && maxw=$w
  done
  local inner=$(( maxw + 1 ))
  local prompt_cols=${__tzc_prompt_cols:-0}
  (( prompt_cols < 0 )) && prompt_cols=0
  local indent=$(( ( prompt_cols + cursor_col ) % columns ))
  # shift left near the right edge so the box still fits on screen
  (( indent > columns - 12 )) && indent=$(( columns > 12 ? columns - 12 : 0 ))
  local avail=$(( columns - 2 - indent ))
  if (( avail < 10 )); then
    indent=0
    avail=$(( columns - 2 ))
  fi
  (( avail < 10 )) && return 1
  (( inner > avail )) && inner=$avail

  local hbar='─' vbar='│' tl='┌' tr='┐' bl='└' br='┘'
  if [[ ! -o multibyte ]]; then
    hbar='-' vbar='|' tl='+' tr='+' bl='+' br='+'
  fi
  local bar= pad= i
  for ((i=0;i<inner;i++)); do bar+=$hbar; done
  for ((i=0;i<indent;i++)); do pad+=' '; done

  local menu=$'\n'
  local -i pos=$(( base + 1 ))
  local top_line="$pad$tl$bar$tr"
  menu+=$top_line
  pos+=${#top_line}

  local r idx line content marker disp_label disp_desc
  local -a row_start row_label_off row_label_len row_desc_off row_desc_len row_selected
  for ((r=1; r<=rows; r++)); do
    menu+=$'\n'
    (( pos++ ))
    idx=$(( top + r ))
    rec=${__tzc_candidates[idx]}
    IFS=$'\x1f' f=( ${=rec} )
    local label=${f[1]} desc=${f[3]}
    marker='  '
    row_selected[r]=0
    (( idx == sel + 1 )) && { marker='> '; row_selected[r]=1; }
    local leading=" $marker$label"
    disp_label=$label
    disp_desc=$desc
    if [[ -n $desc ]] && (( ${#leading} + 2 + ${#desc} <= inner )); then
      content="$leading  $desc"
    elif (( ${#leading} <= inner )); then
      content=$leading
      disp_desc=
    else
      disp_desc=
      local avail=$(( inner - 3 ))
      (( avail < 1 )) && avail=1
      if (( ${#label} > avail )); then
        if (( avail > 1 )); then
          disp_label="${label[1,avail-1]}…"
        else
          disp_label="${label[1,avail]}"
        fi
      fi
      content=" $marker$disp_label"
      (( ${#content} > inner )) && content="${content[1,inner]}"
    fi
    content=${(r:inner:: :)content}
    row_start[r]=$pos
    line="$pad$vbar$content$vbar"
    menu+=$line
    pos+=${#line}
    row_label_off[r]=$(( row_start[r] + indent + 4 ))
    row_label_len[r]=${#disp_label}
    row_desc_off[r]=$(( row_start[r] + indent + 4 + ${#disp_label} + 2 ))
    row_desc_len[r]=${#disp_desc}
  done

  menu+=$'\n'
  (( pos++ ))
  local bottom_line="$pad$bl$bar$br"
  menu+=$bottom_line

  __tzc_menu_text=$menu

  if [[ $__tzc_color_mode == none ]]; then
    for ((r=1; r<=rows; r++)); do
      (( row_selected[r] )) || continue
      __tzc_menu_regions+=(
        "${row_start[r]} $(( row_start[r] + ${#pad} + inner + 2 )) standout memo=tzc"
      )
    done
    return 0
  fi

  local kindstyle kind
  for ((r=1; r<=rows; r++)); do
    if (( row_selected[r] )); then
      __tzc_menu_regions+=(
        "$(( row_start[r] + indent )) $(( row_start[r] + ${#pad} + inner + 2 )) standout memo=tzc"
      )
      continue
    fi
    kind=${__tzc_c_kind[$(( top + r ))]}
    kindstyle=${__tzc_palette[$kind]:-${__tzc_palette[file]}}
    (( row_label_len[r] )) &&
      __tzc_menu_regions+=(
        "${row_label_off[r]} $(( row_label_off[r] + row_label_len[r] )) $kindstyle memo=tzc"
      )
    (( row_desc_len[r] )) &&
      __tzc_menu_regions+=(
        "${row_desc_off[r]} $(( row_desc_off[r] + row_desc_len[r] )) ${__tzc_palette[desc]} memo=tzc"
      )
  done
  return 0
}
