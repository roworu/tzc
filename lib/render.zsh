# build the POSTDISPLAY menu and its region_highlight entries.

typeset -gA __tzc_palette
typeset -g __tzc_color_mode
typeset -g __tzc_menu_text
typeset -ga __tzc_menu_regions
typeset -gi __tzc_menu_rows
typeset -gi __tzc_prompt_cols=-1
typeset -ga __tzc_wrapped

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
        history 'fg=#f5c2e7'
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
        history 'fg=218'
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

  local top=${__tzc_top:-0} sel=${__tzc_selected:-0}
  (( sel < 0 )) && sel=0
  (( sel >= total )) && sel=$(( total - 1 ))

  # width from every label and the selected description, the only description
  # rendered; a long description on another candidate must not widen the box
  local maxw=0 rec w
  local -a f
  IFS=$'\x1f' f=( ${=__tzc_candidates[sel+1]} )
  (( ${#f[3]} + 1 > maxw )) && maxw=$(( ${#f[3]} + 1 ))
  for rec in "${__tzc_candidates[@]}"; do
    IFS=$'\x1f' f=( ${=rec} )
    w=$(( 3 + ${#f[1]} ))
    (( w > maxw )) && maxw=$w
  done

  local inner=$(( maxw + 1 ))
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
  local max_width=${__tzc_max_width:-80}
  [[ $max_width == <-> ]] || max_width=80
  (( max_width < 12 )) && max_width=12
  # the setting caps the popup width; keep the box anchored to the cursor
  (( inner > max_width - 2 )) && inner=$(( max_width - 2 ))

  # wrap the selected description to the box interior; its line count changes
  # the menu height
  IFS=$'\x1f' f=( ${=__tzc_candidates[sel+1]} )
  local -a desc_lines
  if [[ -n ${f[3]} ]]; then
    __tzc_wrap_text "${f[3]}" $(( inner - 1 ))
    desc_lines=("${__tzc_wrapped[@]}")
  fi
  local row_budget=${__tzc_max_rows:-10}
  [[ $row_budget == <-> ]] || row_budget=10
  (( row_budget < 1 )) && row_budget=1

  local desc_extra=0
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

  local hbar='─' vbar='│' tl='┌' tr='┐' bl='└' br='┘' ml='├' mr='┤'
  if [[ ! -o multibyte ]]; then
    hbar='-' vbar='|' tl='+' tr='+' bl='+' br='+' ml='+' mr='+'
  fi
  local bar= pad= i
  for ((i=0;i<inner;i++)); do bar+=$hbar; done
  for ((i=0;i<indent;i++)); do pad+=' '; done

  local menu=$'\n'
  local -i pos=$(( base + 1 ))
  local top_line="$pad$tl$bar$tr"
  menu+=$top_line
  pos+=${#top_line}

  local r idx line content marker disp_label
  local -a row_start row_label_off row_label_len row_selected
  for ((r=1; r<=rows; r++)); do
    menu+=$'\n'
    (( pos++ ))
    idx=$(( top + r ))
    rec=${__tzc_candidates[idx]}
    IFS=$'\x1f' f=( ${=rec} )
    local label=${f[1]}
    marker='  '
    row_selected[r]=0
    (( idx == sel + 1 )) && { marker='> '; row_selected[r]=1 }
    disp_label=$label
    local label_avail=$(( inner - 3 ))
    (( label_avail < 1 )) && label_avail=1
    if (( ${#label} > label_avail )); then
      if (( label_avail > 1 )); then
        disp_label="${label[1,label_avail-1]}…"
      else
        disp_label="${label[1,label_avail]}"
      fi
    fi
    content=" $marker$disp_label"
    (( ${#content} > inner )) && content="${content[1,inner]}"
    content=${(r:inner:: :)content}
    row_start[r]=$pos
    line="$pad$vbar$content$vbar"
    menu+=$line
    pos+=${#line}
    row_label_off[r]=$(( row_start[r] + indent + 4 ))
    row_label_len[r]=${#disp_label}
  done

  # selected description as a multi-line section inside the box
  local -a desc_off desc_len
  if (( ${#desc_lines} )); then
    menu+=$'\n'
    (( pos++ ))
    local sep_line="$pad$ml$bar$mr"
    menu+=$sep_line
    pos+=${#sep_line}
    local dl dl_content
    for dl in "${desc_lines[@]}"; do
      menu+=$'\n'
      (( pos++ ))
      desc_off+=($(( pos + indent + 2 )))
      desc_len+=(${#dl})
      dl_content=" $dl"
      dl_content=${(r:inner:: :)dl_content}
      line="$pad$vbar$dl_content$vbar"
      menu+=$line
      pos+=${#line}
    done
  fi

  menu+=$'\n'
  (( pos++ ))
  local bottom_line="$pad$bl$bar$br"
  menu+=$bottom_line
  pos+=${#bottom_line}

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
  done
  local di
  for ((di=1; di<=${#desc_len}; di++)); do
    __tzc_menu_regions+=(
      "${desc_off[di]} $(( desc_off[di] + desc_len[di] )) ${__tzc_palette[desc]} memo=tzc"
    )
  done
  return 0
}
