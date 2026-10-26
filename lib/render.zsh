# build the POSTDISPLAY menu and its region_highlight entries.

typeset -gA __tzc_palette
typeset -g __tzc_menu_text
typeset -ga __tzc_menu_regions
typeset -gi __tzc_menu_rows
typeset -gi __tzc_prompt_cols=-1
typeset -ga __tzc_wrapped __tzc_box_lines __tzc_box_regions

__tzc_init_render() {
  emulate -L zsh
  __tzc_palette=()
  [[ -n ${TZC_NO_COLOR:-} || -n ${NO_COLOR:-} ]] && return 0
  # palette slots instead of fixed rgb so the menu follows the terminal theme
  # and stays readable on both light and dark backgrounds
  __tzc_palette=(
    desc 'fg=8'
    subcommand 'fg=magenta'
    suggestion 'fg=cyan'
    option 'fg=yellow'
    command 'fg=green'
    folder 'fg=blue'
    file 'fg=default'
    history 'fg=8'
  )
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

# split text into lines no wider than $2; sets __tzc_wrapped
__tzc_wrap_text() {
  emulate -L zsh
  setopt localoptions noglob
  local text=$1 width=$2
  local -a words lines
  local word line=
  local IFS=$' \t\n'
  (( width < 1 )) && width=1
  words=( ${=text} )
  for word in "${words[@]}"; do
    if (( ${#word} > width )); then
      [[ -n $line ]] && { lines+=("$line"); line= }
      while (( ${#word} > width )); do
        lines+=("${word[1,width]}")
        word=${word[width+1,-1]}
      done
      line=$word
    elif [[ -z $line ]]; then
      line=$word
    elif (( ${#line} + 1 + ${#word} <= width )); then
      line+=" $word"
    else
      lines+=("$line")
      line=$word
    fi
  done
  [[ -n $line ]] && lines+=("$line")
  __tzc_wrapped=("${lines[@]}")
  return 0
}

# widest "  > label" row of the candidate array named $1, in REPLY
__tzc_label_width() {
  emulate -L zsh
  setopt localoptions noglob
  local rec IFS=$'\x1f'
  local -a f
  REPLY=0
  for rec in "${(@P)1}"; do
    f=( ${=rec} )
    (( 3 + ${#f[1]} > REPLY )) && REPLY=$(( 3 + ${#f[1]} ))
  done
  return 0
}

# draw the box into __tzc_box_lines and __tzc_box_regions ("line start end
# style", columns relative to the box). $1 names the candidate array, then
# selected index, top, rows, inner width and any description lines.
__tzc_box() {
  emulate -L zsh
  setopt localoptions noglob
  local -a recs f
  local IFS=$'\x1f'
  recs=( "${(@P)1}" )
  local sel=$2 top=$3 rows=$4 inner=$5
  shift 5
  local hbar='─' vbar='│' tl='┌' tr='┐' bl='└' br='┘' ml='├' mr='┤'
  if [[ ! -o multibyte ]]; then
    hbar='-' vbar='|' tl='+' tr='+' bl='+' br='+' ml='+' mr='+'
  fi
  local bar=${(pl:inner::$hbar:)}
  __tzc_box_lines=( $tl$bar$tr )
  __tzc_box_regions=()
  # labels are cut only when the box is capped (inner >= 10), so the cut label
  # always fits and keeps at least one character
  local r idx label disp style label_avail=$(( inner - 3 ))
  for ((r=1; r<=rows; r++)); do
    idx=$(( top + r ))
    f=( ${=recs[idx]} )
    label=${f[1]}
    disp=$label
    (( ${#label} > label_avail )) && disp="${label[1,label_avail-1]}…"
    if (( idx == sel + 1 )); then label="> $disp"; else label="  $disp"; fi
    __tzc_box_lines+=( $vbar${(r:inner:: :)${:- $label}}$vbar )
    if (( idx == sel + 1 )); then
      __tzc_box_regions+=( "$(( r + 1 )) 0 $(( inner + 2 )) standout" )
      continue
    fi
    style=${__tzc_palette[${f[4]}]:-${__tzc_palette[file]}}
    [[ -n $style ]] && (( ${#disp} )) &&
      __tzc_box_regions+=( "$(( r + 1 )) 4 $(( 4 + ${#disp} )) $style" )
  done
  if (( $# )); then
    __tzc_box_lines+=( $ml$bar$mr )
    local dl
    for dl; do
      __tzc_box_lines+=( $vbar${(r:inner:: :)${:- $dl}}$vbar )
      (( ${#__tzc_palette} )) &&
        __tzc_box_regions+=( "${#__tzc_box_lines} 2 $(( 2 + ${#dl} )) ${__tzc_palette[desc]}" )
    done
  fi
  __tzc_box_lines+=( $bl$bar$br )
  return 0
}

# build __tzc_menu_text and __tzc_menu_regions. $1 is the offset of the
# leading newline in BUFFER+POSTDISPLAY (i.e. #BUFFER); $2 is the display
# width of BUFFER up to CURSOR.
__tzc_render_menu() {
  emulate -L zsh
  setopt localoptions noglob extendedglob
  local base=$1
  local cursor_col=${2:-0}
  local IFS=$'\x1f'
  __tzc_menu_text=
  __tzc_menu_regions=()
  __tzc_menu_rows=0
  local total=${#__tzc_candidates}
  (( total )) || return 1

  local columns=${COLUMNS:-80} lines=${LINES:-24}
  (( columns < 1 )) && columns=80
  (( lines < 5 )) && lines=24
  local max_width=${__tzc_max_width:-80}
  local row_budget=${__tzc_max_rows:-10}

  local top=${__tzc_top:-0} sel=${__tzc_selected:-0}
  (( sel >= total )) && sel=$(( total - 1 ))
  (( sel < 0 )) && sel=0

  # width from every label and the selected description, the only description
  # rendered; a long description on another candidate must not widen the box
  local -a f
  f=( ${=__tzc_candidates[sel+1]} )
  local sel_desc=${f[3]}
  __tzc_label_width __tzc_candidates
  (( REPLY < ${#sel_desc} + 1 )) && REPLY=$(( ${#sel_desc} + 1 ))
  local inner=$(( REPLY + 1 ))
  # the setting caps the box; keep the popup anchored to the cursor
  (( inner > max_width - 2 )) && inner=$(( max_width - 2 ))

  local prompt_cols=${__tzc_prompt_cols:-0}
  (( prompt_cols < 0 )) && prompt_cols=0
  local indent=$(( ( prompt_cols + cursor_col ) % columns ))
  # shift left near the right edge; keep the last column empty so zle never
  # wraps a menu line
  (( indent > columns - 13 )) && indent=$(( columns > 13 ? columns - 13 : 0 ))
  local avail=$(( columns - 3 - indent ))
  if (( avail < 10 )); then
    indent=0
    avail=$(( columns - 3 ))
  fi
  (( avail < 10 )) && return 1
  (( inner > avail )) && inner=$avail

  # wrap the selected description to the box interior; its line count changes
  # the menu height
  local desc_extra=0
  local -a desc_lines
  if [[ -n $sel_desc ]]; then
    __tzc_wrap_text "$sel_desc" $(( inner - 1 ))
    desc_lines=("${__tzc_wrapped[@]}")
  fi
  if (( ${#desc_lines} )); then
    # the description counts against the row budget; keep one candidate row
    local max_desc_lines=$(( row_budget - 2 ))
    (( max_desc_lines > lines - 5 )) && max_desc_lines=$(( lines - 5 ))
    (( max_desc_lines < 0 )) && max_desc_lines=0
    if (( max_desc_lines == 0 )); then
      desc_lines=()
    elif (( ${#desc_lines} > max_desc_lines )); then
      desc_lines=("${(@)desc_lines[1,max_desc_lines]}")
      if (( ${#desc_lines[-1]} < inner - 1 )); then
        desc_lines[-1]+="…"
      else
        desc_lines[-1]="${desc_lines[-1][1,inner-2]}…"
      fi
    fi
    (( ${#desc_lines} )) && desc_extra=$(( 1 + ${#desc_lines} ))
  fi
  local max_rows=$(( row_budget - desc_extra ))
  (( max_rows > lines - 3 - desc_extra )) && max_rows=$(( lines - 3 - desc_extra ))
  (( max_rows < 1 )) && return 1
  local rows=$total
  (( rows > max_rows )) && rows=$max_rows
  (( top < 0 )) && top=0
  (( top > total - rows )) && top=$(( total - rows ))
  (( sel < top )) && top=$sel
  (( sel >= top + rows )) && top=$(( sel - rows + 1 ))
  __tzc_top=$top
  __tzc_menu_rows=$rows

  __tzc_box __tzc_candidates $sel $top $rows $inner "${desc_lines[@]}"

  # region offsets are base plus the menu text before each line
  local menu= i pad=${(l:indent:: :)}
  local -a line_off
  for ((i=1; i<=${#__tzc_box_lines}; i++)); do
    line_off[i]=$(( base + ${#menu} + 1 ))
    menu+=$'\n'$pad${__tzc_box_lines[i]}
  done
  __tzc_menu_text=$menu

  local reg start
  local -a rf
  IFS=' '
  for reg in "${__tzc_box_regions[@]}"; do
    rf=( ${=reg} )
    start=$(( line_off[rf[1]] + indent + rf[2] ))
    # without colors the standout bar also covers the indent
    [[ ${rf[4]} == standout ]] && (( ! ${#__tzc_palette} )) && start=${line_off[rf[1]]}
    __tzc_menu_regions+=( "$start $(( line_off[rf[1]] + indent + rf[3] )) ${rf[4]} memo=tzc" )
  done
  return 0
}
