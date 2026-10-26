# zsh completion engine: line parsing, the spec walk, PATH and file candidates.

typeset -ga __tzc_wrappers __tzc_redirects
__tzc_wrappers=(builtin command doas env exec nice nohup sudo time watch xargs)
__tzc_redirects=('>' '>>' '<' '<<' '2>' '2>>' '&>' '&>>' '>|' '<>')

typeset -gA __tzc_wrapper_values __tzc_kind_order
__tzc_wrapper_values=(
  sudo '-u -g -h -p -C -D -R -T -U -r -t --user --group --host --prompt --chdir'
  doas '-u -C'
  env '-u -C -S --unset --chdir --split-string'
  nice '-n --adjustment'
  watch '-n --interval'
  xargs '-I -n -L -P -d -E -s -a --max-args --max-procs --delimiter --arg-file'
  time '-f -o --format --output'
  exec '-a'
)
__tzc_kind_order=(subcommand 0 suggestion 1 option 2 command 3 folder 4 file 5)

typeset -ga __tzc_p_words __tzc_cmd_words __tzc_opt_ids __tzc_persistent
typeset -ga __tzc_c_label __tzc_c_insert __tzc_c_desc __tzc_c_kind __tzc_c_score __tzc_c_prio
typeset -ga __tzc_candidates __tzc_hist_candidates __tzc_prog_names __tzc_pkg_lines
typeset -g __tzc_pkg_stamp=
# __tzc_add_nodes cache: split fields of the last node list (nc) and its
# empty-query rows (nc_e)
typeset -g __tzc_nc_key=
typeset -gi __tzc_nc_e=0
typeset -ga __tzc_nc_id __tzc_nc_names __tzc_nc_desc __tzc_nc_flags __tzc_nc_prio __tzc_nc_rows
typeset -ga __tzc_nc_e_label __tzc_nc_e_insert __tzc_nc_e_desc __tzc_nc_e_kind __tzc_nc_e_score __tzc_nc_e_prio
# __tzc_add_from_spec cache: the walk state for the last words (w)
typeset -g __tzc_w_key= __tzc_w_spec=
typeset -ga __tzc_w_state __tzc_w_used __tzc_w_opt_ids

# history suggestions: max entries in the history box; 0 disables. the recent
# window is cached so keystrokes scan an array, not the whole history map.
typeset -g __tzc_history=${TZC_HISTORY:-3}
[[ $__tzc_history == <-> ]] || __tzc_history=3
__tzc_history=$(( 10#$__tzc_history ))
typeset -ga __tzc_hist_lines
typeset -g __tzc_hist_stamp=

# quote text for the open quote; close adds the closing quote. a leading ~ is
# left unescaped so home paths keep working.
__tzc_escape() {
  emulate -L zsh
  local text=$1 quote=$2 close=$3
  local out= i ch
  if [[ $quote == "'" ]]; then
    out="'"
    for ((i=1;i<=${#text};i++)); do
      ch=${text[i]}
      if [[ $ch == "'" ]]; then out+="'\\''"; else out+=$ch; fi
    done
    (( close )) && out+="'"
  elif [[ -n $quote ]]; then
    out=$quote
    for ((i=1;i<=${#text};i++)); do
      ch=${text[i]}
      case $ch in
        ('"'|'\'|'$'|'`') out+="\\$ch" ;;
        (*) out+=$ch ;;
      esac
    done
    (( close )) && out+=$quote
  else
    if [[ $text == '~'* ]]; then
      out='~'
      text=${text[2,-1]}
    fi
    [[ -n $text ]] && out+=${(q)text}
    # (q) leaves ! alone, which history expansion would eat
    out=${out//!/\\!}
  fi
  REPLY=$out
  return 0
}

# exact prefix 0, case-insensitive prefix 1, substring (3+ chars) 2
__tzc_score() {
  emulate -L zsh
  local name=$1 query=$2
  local bq=${(b)query}
  if [[ $name == ${~bq}* ]]; then REPLY=0; return 0; fi
  local lower_name=${(L)name} lower_query=${(L)query}
  local blq=${(b)lower_query}
  if [[ $lower_name == ${~blq}* ]]; then REPLY=1; return 0; fi
  if (( ${#lower_query} >= 3 )) && [[ $lower_name == *${~blq}* ]]; then
    REPLY=2
    return 0
  fi
  return 1
}

# split the text before the cursor into words and the word being typed.
# sets __tzc_p_words/prefix/start/quote/option/redirect (start is 0-based).
__tzc_parse_line() {
  emulate -L zsh
  local line=$1
  local -a words
  local current= quote= started=0 start=0 prefix option=
  local escaped=0 i ch equals= eq_len
  for ((i=1;i<=${#line};i++)); do
    ch=${line[i]}
    if (( escaped )); then current+=$ch; escaped=0; continue; fi
    if [[ -n $quote ]]; then
      if [[ $ch == "$quote" ]]; then quote=
      elif [[ $ch == '\' && $quote == '"' ]]; then escaped=1
      else current+=$ch
      fi
      continue
    fi
    case $ch in
      ("'"|'"')
        if (( ! started )); then started=1; start=$((i-1)); fi
        quote=$ch
        ;;
      ('\')
        if (( ! started )); then started=1; start=$((i-1)); fi
        escaped=1
        ;;
      ([[:space:]])
        if (( started )); then
          words+=("$current")
          current=
          started=0
          equals=
        fi
        ;;
      (*)
        if (( ! started )); then started=1; start=$((i-1)); fi
        if [[ $ch == '=' && -z $equals ]]; then
          equals=$(( i - 1 - start ))
          eq_len=$(( ${#current} + 1 ))
        fi
        current+=$ch
        ;;
    esac
  done
  prefix=$current
  local word_start
  (( started )) && word_start=$start || word_start=${#line}

  # an open --name=value completes the value and replaces from after the =
  if [[ -n $equals && ${line[start+1]} == - ]]; then
    option=${line[start+1,start+equals]}
    prefix=${current[eq_len+1,-1]}
    word_start=$(( start + equals + 1 ))
  fi

  __tzc_p_words=("${words[@]}")
  __tzc_p_prefix=$prefix
  __tzc_p_start=$word_start
  __tzc_p_quote=$quote
  __tzc_p_option=$option
  __tzc_p_redirect=0
  (( ${#words} && ${__tzc_redirects[(Ie)${words[-1]}]} )) && __tzc_p_redirect=1
  return 0
}

# complete words before the current one, skipping wrappers and assignments
__tzc_command_words() {
  emulate -L zsh
  setopt localoptions noglob
  local -a words=("$@")
  local index=0 wrapper= count=${#words}
  local word name assignment
  local -a values
  while (( index < count )); do
    word=${words[index+1]}
    assignment=0
    if [[ $word == *=* ]]; then
      name=${word%%=*}
      [[ $name == [A-Za-z_]* && $name != *[!A-Za-z0-9_]* ]] && assignment=1
    fi
    if (( ${__tzc_wrappers[(Ie)$word]} )); then
      wrapper=$word
    elif [[ -n $wrapper && $word == -* ]]; then
      values=( ${=__tzc_wrapper_values[$wrapper]} )
      (( ${values[(Ie)$word]} )) && (( index++ ))
    elif (( ! assignment )); then
      break
    fi
    (( index++ ))
  done
  __tzc_cmd_words=("${(@)words[index+1,-1]}")
  return 0
}

__tzc_push() {
  __tzc_c_label+=("$1")
  __tzc_c_insert+=("$2")
  __tzc_c_desc+=("$3")
  __tzc_c_kind+=("$4")
  __tzc_c_score+=("$5")
  local prio=${6:-50}
  (( prio > 100 )) && prio=100
  (( prio < 0 )) && prio=0
  __tzc_c_prio+=("$prio")
  return 0
}

# rebuild the recent-history window only when the history changes
__tzc_hist_refresh() {
  emulate -L zsh
  setopt localoptions noglob
  # ${#history} is linear on the special parameter, so HISTCMD is the stamp
  local stamp=${HISTCMD:-0}
  [[ $stamp == $__tzc_hist_stamp ]] && return 0
  __tzc_hist_stamp=$stamp
  local -a lines
  local key=$(( stamp - 1 ))
  local scans=0 window=500
  while (( key > 0 && scans < window * 2 && ${#lines} < window )); do
    (( ${+history[$key]} )) && lines+=("${history[$key]}")
    scans=$(( scans + 1 ))
    key=$(( key - 1 ))
  done
  __tzc_hist_lines=("${lines[@]}")
  return 0
}

# recent history lines that start with the typed line, newest first, as
# candidate records in __tzc_hist_candidates
__tzc_add_history() {
  emulate -L zsh
  setopt localoptions noglob
  local limit=${__tzc_history:-0}
  (( limit > 0 )) || return 0
  local line=$__tzc_result_line
  [[ -n ${line//[[:space:]]/} ]] || return 0
  __tzc_hist_refresh
  local -a seen hits
  local entry count=0 bl=${(b)line}
  hits=( ${(M)__tzc_hist_lines:#${~bl}*} )
  for entry in "${hits[@]}"; do
    (( count >= limit )) && break
    [[ $entry == "$line" ]] && continue
    [[ $entry == *[[:cntrl:]]* ]] && continue
    (( ${seen[(Ie)$entry]} )) && continue
    seen+=("$entry")
    __tzc_hist_candidates+=("$entry"$'\x1f'"$entry"$'\x1f'$'\x1f'history)
    (( count += 1 ))
  done
  return 0
}

# names is a \x1d list; the best matching name supplies the insert
__tzc_add_names() {
  emulate -L zsh
  setopt localoptions noglob
  local names_text=$1 desc=$2 kind=$3 prio=$4 hidden=${5:-0}
  local -a names
  local IFS=$'\x1d'
  names=( ${=names_text} )
  local name best= best_score= best_len=-1 sc
  for name in "${names[@]}"; do
    __tzc_score "$name" "$__tzc_p_prefix" || continue
    sc=$REPLY
    if (( best_len < 0 || sc < best_score || (sc == best_score && ${#name} > best_len) )); then
      best=$name
      best_score=$sc
      best_len=${#name}
    fi
  done
  (( best_len < 0 )) && return 0
  (( hidden )) && [[ $best != $__tzc_p_prefix ]] && return 0
  [[ $best == *[[:cntrl:]]* ]] && return 0
  # a key= suggestion waits for its value, so no space after it
  if [[ $best == *= ]]; then
    __tzc_escape "$best" "$__tzc_p_quote" 0
    __tzc_push "$best" "$REPLY" "$desc" "$kind" "$best_score" "$prio"
    return 0
  fi
  __tzc_escape "$best" "$__tzc_p_quote" 1
  __tzc_push "$best" "$REPLY " "$desc" "$kind" "$best_score" "$prio"
  return 0
}

# add candidates for node ids in "$@"; kind is option or subcommand.
# this is the hot path for option-heavy specs, so fields are scored and pushed
# inline instead of through __tzc_record/__tzc_score/__tzc_push.
# used (caller-local) skips options that were already given.
__tzc_add_nodes() {
  emulate -L zsh
  setopt localoptions noglob extendedglob
  local kind=$1
  shift
  local -a names idx
  local k oid flags name best best_score best_len sc label insert
  local query=$__tzc_p_prefix us=$'\x1f' gs=$'\x1d'
  local bq=${(b)query} blq=${(b)${(L)query}}
  local qlen=${#query}
  # the node list stays the same while a word is typed, so its fields are
  # split once and kept with the rows of the empty query
  local key="$__tzc_spec_loaded$us$kind$us$__tzc_p_quote$us$*"
  if [[ $key != $__tzc_nc_key ]]; then
    local -a f
    __tzc_nc_key=$key
    __tzc_nc_e=0
    __tzc_nc_id=() __tzc_nc_names=() __tzc_nc_desc=() __tzc_nc_flags=()
    __tzc_nc_prio=() __tzc_nc_rows=()
    for oid in "$@"; do
      f=( "${(@ps:\x1f:)__tzc_s_nodes[$oid]}" )
      sc=${f[4]:-50}
      (( sc > 100 )) && sc=100
      (( sc < 0 )) && sc=0
      __tzc_nc_id+=("$oid")
      __tzc_nc_names+=("${f[2]}")
      __tzc_nc_desc+=("${f[3]}")
      __tzc_nc_flags+=("${f[5]}")
      __tzc_nc_prio+=("$sc")
      __tzc_nc_rows+=("${#__tzc_nc_id}$us${f[2]}")
    done
  fi
  if [[ -z $query ]] && (( __tzc_nc_e )); then
    __tzc_c_label+=("${__tzc_nc_e_label[@]}")
    __tzc_c_insert+=("${__tzc_nc_e_insert[@]}")
    __tzc_c_desc+=("${__tzc_nc_e_desc[@]}")
    __tzc_c_kind+=("${__tzc_nc_e_kind[@]}")
    __tzc_c_score+=("${__tzc_nc_e_score[@]}")
    __tzc_c_prio+=("${__tzc_nc_e_prio[@]}")
    return 0
  fi
  if [[ -z $query ]]; then
    idx=( {1..${#__tzc_nc_id}} )
    (( ${#__tzc_nc_id} )) || idx=()
  elif (( qlen >= 3 )); then
    # a superset of the matching rows; the loop scores each name
    idx=( ${${(M)__tzc_nc_rows:#<->$us*(#i)${~bq}*}%%$us*} )
  else
    idx=( ${${(M)__tzc_nc_rows:#<->$us(|*$gs)(#i)${~bq}*}%%$us*} )
  fi
  local first=$(( ${#__tzc_c_label} + 1 ))
  for k in "${idx[@]}"; do
    flags=${__tzc_nc_flags[k]}
    [[ $kind == option ]] && (( ${+used[${__tzc_nc_id[k]}]} )) && [[ $flags != *R* ]] && continue
    names=( ${(ps:\x1d:)__tzc_nc_names[k]} )
    best= best_score= best_len=-1
    for name in "${names[@]}"; do
      if [[ $name == ${~bq}* ]]; then sc=0
      elif [[ ${(L)name} == ${~blq}* ]]; then sc=1
      elif (( qlen >= 3 )) && [[ ${(L)name} == *${~blq}* ]]; then sc=2
      else continue
      fi
      if (( best_len < 0 || sc < best_score ||
            (sc == best_score && ${#name} > best_len) )); then
        best=$name
        best_score=$sc
        best_len=${#name}
      fi
    done
    (( best_len < 0 )) && continue
    [[ $flags == *H* && $best != $query ]] && continue
    [[ $best == *[[:cntrl:]]* ]] && continue
    label=$best
    insert="$best "
    if [[ $kind == option ]]; then
      (( ${#names} > 1 )) && label="${(j:, :)names}"
    elif [[ -n $__tzc_p_quote || $best == '~'* ]]; then
      __tzc_escape "$best" "$__tzc_p_quote" 1
      insert="$REPLY "
    elif [[ $best == *[[:punct:][:space:]]* ]]; then
      # __tzc_escape inline: a call per node is most of the hot loop
      insert="${${(q)best}//!/\\!} "
    fi
    __tzc_c_label+=("$label")
    __tzc_c_insert+=("$insert")
    __tzc_c_desc+=("${__tzc_nc_desc[k]}")
    __tzc_c_kind+=("$kind")
    __tzc_c_score+=("$best_score")
    __tzc_c_prio+=("${__tzc_nc_prio[k]}")
  done
  if [[ -z $query ]]; then
    __tzc_nc_e=1
    __tzc_nc_e_label=() __tzc_nc_e_insert=() __tzc_nc_e_desc=()
    __tzc_nc_e_kind=() __tzc_nc_e_score=() __tzc_nc_e_prio=()
    if (( first <= ${#__tzc_c_label} )); then
      __tzc_nc_e_label=("${(@)__tzc_c_label[first,-1]}")
      __tzc_nc_e_insert=("${(@)__tzc_c_insert[first,-1]}")
      __tzc_nc_e_desc=("${(@)__tzc_c_desc[first,-1]}")
      __tzc_nc_e_kind=("${(@)__tzc_c_kind[first,-1]}")
      __tzc_nc_e_score=("${(@)__tzc_c_score[first,-1]}")
      __tzc_nc_e_prio=("${(@)__tzc_c_prio[first,-1]}")
    fi
  fi
  return 0
}

__tzc_add_commands() {
  emulate -L zsh
  setopt localoptions noglob extendedglob
  __tzc_programs
  local query=$__tzc_p_prefix name desc score insert
  local -a names
  if [[ -z $query ]]; then
    local i
    for ((i=1;i<=${#__tzc_prog_names} && i<=200;i++)); do
      name=${__tzc_prog_names[i]}
      desc=${__tzc_spec_desc[$name]}
      __tzc_escape "$name" "$__tzc_p_quote" 1
      __tzc_push "$name" "$REPLY " "$desc" command 0 50
    done
    return 0
  fi
  local bq=${(b)query}
  if (( ${#query} >= 3 )); then
    names=( ${(M)__tzc_prog_names:#(#i)*${~bq}*} )
  else
    names=( ${(M)__tzc_prog_names:#(#i)${~bq}*} )
  fi
  for name in "${names[@]}"; do
    if [[ $name == ${~bq}* ]]; then score=0
    elif [[ $name == (#i)${~bq}* ]]; then score=1
    else score=2
    fi
    if [[ -z $__tzc_p_quote && $name != '~'* ]]; then
      insert=${${(q)name}//!/\\!}
    else
      __tzc_escape "$name" "$__tzc_p_quote" 1
      insert=$REPLY
    fi
    __tzc_c_label+=("$name")
    __tzc_c_insert+=("$insert ")
    __tzc_c_desc+=("${__tzc_spec_desc[$name]}")
    __tzc_c_kind+=(command)
    __tzc_c_score+=("$score")
    __tzc_c_prio+=(50)
  done
  return 0
}

# load one manager's plain-text package cache, regenerated by
# completions/tools/package-cache.zsh
__tzc_pkg_load() {
  emulate -L zsh
  setopt localoptions noglob
  local manager=$1
  [[ -n $manager && $manager != *[!A-Za-z0-9_.-]* ]] || return 1
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/tzc/packages
  local file="$dir/$manager"
  # reload only when the cache file changes, not after every command
  zmodload zsh/stat 2>/dev/null
  local -A st
  local mtime=- size=-
  zstat -H st -- "$file" 2>/dev/null && { mtime=${st[mtime]}; size=${st[size]} }
  local stamp="$file:$mtime:$size"
  [[ $__tzc_pkg_stamp == $stamp ]] && return 0
  __tzc_pkg_stamp=$stamp
  __tzc_pkg_lines=()
  [[ $mtime != - && -r $file ]] || return 1
  __tzc_pkg_lines=( ${(f)"$(<$file)"} )
  return 0
}

# package names for the typed prefix from the manager's cache
__tzc_add_packages() {
  emulate -L zsh
  setopt localoptions noglob extendedglob
  local manager=$1
  __tzc_pkg_load "$manager" || return 0
  (( ${#__tzc_pkg_lines} )) || return 0
  local query=$__tzc_p_prefix
  local -a lines
  local line name desc insert count=0 score=0
  if [[ -z $query ]]; then
    lines=( "${(@)__tzc_pkg_lines[1,200]}" )
  else
    # keep the scans off the keystroke path: exact prefix, then case-insensitive
    # prefix, then substring only when nothing matched
    local bq=${(b)query}
    # the cache is LC_ALL=C sorted, so exact-prefix lines are contiguous and
    # a binary search finds the first one
    local lo=1 hi=$(( ${#__tzc_pkg_lines} + 1 )) mid
    while (( lo < hi )); do
      mid=$(( (lo + hi) / 2 ))
      if [[ ${__tzc_pkg_lines[mid]} < $query ]]; then lo=$(( mid + 1 )); else hi=$mid; fi
    done
    lines=( ${(M)${(@)__tzc_pkg_lines[lo,lo+999]}:#${~bq}*} )
    if (( ${#lines} == 0 )); then
      lines=( ${(M)__tzc_pkg_lines:#(#i)${~bq}*} )
      score=1
    fi
    if (( ${#lines} == 0 && ${#query} >= 3 )); then
      lines=( ${(M)__tzc_pkg_lines:#(#i)*${~bq}*} )
      score=2
    fi
  fi
  # cache lines are name<TAB>description; older caches hold only the name
  for line in "${lines[@]}"; do
    name=${line%%$'\t'*}
    [[ -n $name && $name != *[[:space:][:cntrl:]]* ]] || continue
    desc=
    [[ $line == *$'\t'* ]] && desc=${line#*$'\t'}
    [[ -n $desc ]] && desc=${desc//[[:cntrl:]]/ }
    if [[ -z $__tzc_p_quote && $name != '~'* ]]; then
      insert=${${(q)name}//!/\\!}
    else
      __tzc_escape "$name" "$__tzc_p_quote" 1
      insert=$REPLY
    fi
    __tzc_c_label+=("$name")
    __tzc_c_insert+=("$insert ")
    __tzc_c_desc+=("$desc")
    __tzc_c_kind+=(suggestion)
    __tzc_c_score+=("$score")
    __tzc_c_prio+=(50)
    (( ++count >= 200 )) && break
  done
  return 0
}

# files/folders for the typed prefix; files=1 includes non-directories
__tzc_add_paths() {
  emulate -L zsh
  setopt localoptions extendedglob nullglob
  local files=$1 typed=$__tzc_p_prefix
  [[ $typed == '~' ]] && typed='~/'
  local dir_part= name_part= name dir
  if [[ $typed == */* ]]; then
    dir_part=${typed%/*}/
    name_part=${typed##*/}
  else
    name_part=$typed
  fi
  if [[ -z $dir_part ]]; then
    dir=$__tzc_cwd
  elif [[ $dir_part == '~/'* ]]; then
    dir="$HOME/${dir_part#\~/}"
  elif [[ $dir_part == /* ]]; then
    dir=$dir_part
  else
    dir="$__tzc_cwd/$dir_part"
  fi
  # list the directory and match with array filters: backslash escapes from
  # ${(b)} are not honoured for filename generation
  [[ $name_part == .* ]] && setopt localoptions globdots
  local -a dirs others all prefix ci sub ins top
  dirs=( "$dir"/*(N-/:t) )
  (( files )) && others=( "$dir"/*(N^-/:t) )
  # after the globs, which keep the locale order
  local LC_COLLATE=C
  local bq=${(b)name_part} kind lsuf tail close sc us=$'\x1f' rs=$'\x1e'
  local tilde= rest=$dir_part
  [[ -z $__tzc_p_quote && $rest == '~'* ]] && { tilde='~'; rest=${rest[2,-1]} }
  for kind in folder file; do
    if [[ $kind == folder ]]; then
      all=( ${dirs:#*[[:cntrl:]]*} ) lsuf=/ tail= close=0
    else
      all=( ${others:#*[[:cntrl:]]*} ) lsuf= tail=' ' close=1
    fi
    # score 0 exact prefix, 1 case-insensitive prefix, 2 substring (3+ chars)
    prefix=( ${(M)all:#${~bq}*} )
    ci=( ${(M)all:#(#i)${~bq}*} )
    sub=()
    if (( ${#name_part} >= 3 )); then
      sub=( ${(M)all:#(#i)*${~bq}*} )
      sub=( ${sub:|ci} )
    fi
    ci=( ${ci:|prefix} )
    for sc in 0 1 2; do
      case $sc in
        (0) all=( $prefix ) ;;
        (1) all=( $ci ) ;;
        (2) all=( $sub ) ;;
      esac
      (( ${#all} )) || continue
      # only 200 rows are shown and a group sorts by lowercase label, so keep
      # its first 400 by that order (margin for dedupe) before keying them all
      if (( ${#all} > 400 )); then
        ins=( "${(@)all/%/$rs}" )
        top=( "${(@)${(@L)all}/%/$us}" )
        top=( ${(ps:\x1e:)${(j::)top:^ins}} )
        top=( ${${(o)top}[1,400]} )
        top=( ${top#*$us} )
        all=( ${all:*top} )
      fi
      if [[ -z $__tzc_p_quote ]]; then
        # __tzc_escape for the whole list at once
        ins=( "${(@q)${(@)${(@)all/#/$rest}/%/$lsuf}}" )
        ins=( "${(@)${(@)ins//!/\\!}/#/$tilde}" )
      else
        ins=()
        for name in "${all[@]}"; do
          __tzc_escape "$dir_part$name$lsuf" "$__tzc_p_quote" $close
          ins+=("$REPLY")
        done
      fi
      __tzc_c_label+=( "${(@)all/%/$lsuf}" )
      __tzc_c_insert+=( "${(@)ins/%/$tail}" )
      __tzc_c_desc+=( "${(@)all/*/}" )
      __tzc_c_kind+=( "${(@)all/*/$kind}" )
      __tzc_c_score+=( "${(@)all/*/$sc}" )
      __tzc_c_prio+=( "${(@)all/*/50}" )
    done
  done
  return 0
}

# add suggestions and file templates of one arg node
__tzc_add_arg() {
  emulate -L zsh
  setopt localoptions noglob
  local id=$1 rec
  __tzc_record "$id"
  (( ${#__tzc_f} >= 10 )) || return 0
  local sugg=${__tzc_f[7]} tmpl=${__tzc_f[6]}
  if [[ -n $sugg ]]; then
    local IFS=$'\x1c'
    local -a recs
    recs=( ${=sugg} )
    local -a sf
    for rec in "${recs[@]}"; do
      IFS=$'\x1d' sf=( ${=rec} )
      __tzc_add_names "${sf[1]}" "${sf[2]}" suggestion "${sf[3]}" "${sf[4]:-0}"
    done
  fi
  case $tmpl in
    (filepaths) __tzc_add_paths 1 ;;
    (folders) __tzc_add_paths 0 ;;
    (packages:*) __tzc_add_packages "${tmpl#packages:}" ;;
  esac
  return 0
}

# child ids in field $2 (8 options, 9 subcommands, 10 args) of node $1 -> reply
__tzc_ids() {
  emulate -L zsh
  setopt localoptions noglob
  __tzc_record "$1"
  local IFS=$'\x1d'
  reply=( ${=__tzc_f[$2]} )
  return 0
}

# 0-based positional arg index -> arg node id in REPLY; variadic last arg repeats
__tzc_arg_at() {
  emulate -L zsh
  setopt localoptions noglob
  __tzc_ids "$1" 10
  (( ${#reply} )) || return 1
  if (( $2 < ${#reply} )); then
    REPLY=${reply[$2+1]}
    return 0
  fi
  local last=${reply[-1]}
  __tzc_record "$last"
  [[ ${__tzc_f[5]} == *V* ]] && { REPLY=$last; return 0; }
  return 1
}

# REPLY is the first of the ids after $1 that has the exact name $1
__tzc_find_named() {
  emulate -L zsh
  setopt localoptions noglob
  local name=$1 id
  shift
  local -a f names
  for id in "$@"; do
    f=( "${(@ps:\x1f:)__tzc_s_nodes[$id]}" )
    names=( ${(ps:\x1d:)f[2]} )
    (( ${names[(Ie)$name]} )) && { REPLY=$id; return 0; }
  done
  return 1
}

__tzc_build_opt_ids() {
  emulate -L zsh
  __tzc_ids "$__tzc_node" 8
  # unquoted so empty ids drop out
  __tzc_opt_ids=( $reply $__tzc_persistent )
  return 0
}

__tzc_opt_takes_value() {
  emulate -L zsh
  setopt localoptions noglob
  __tzc_record "$1"
  [[ ${__tzc_f[5]} == *T* ]] && return 0
  __tzc_ids "$1" 10
  (( ${#reply} )) || return 1
  __tzc_record "${reply[1]}"
  [[ ${__tzc_f[5]} == *O* ]] && return 1
  return 0
}

# number of value slots, including a pruned T arg
__tzc_opt_arg_count() {
  emulate -L zsh
  setopt localoptions noglob
  __tzc_ids "$1" 10
  REPLY=${#reply}
  [[ ${__tzc_f[5]} == *T* ]] && (( REPLY++ ))
  return 0
}

# cache the persistent option ids per node: walking them on every completion
# is what made option-heavy specs slow
__tzc_collect_persistent() {
  emulate -L zsh
  setopt localoptions noglob
  local node=$1 cached
  if (( ${+__tzc_persist_ids[$node]} )); then
    cached=${__tzc_persist_ids[$node]}
  else
    local -a ids hits
    local IFS=$'\x1d' id
    local -a f
    f=( "${(@ps:\x1f:)__tzc_s_nodes[$node]}" )
    ids=( ${=f[8]} )
    for id in "${ids[@]}"; do
      f=( "${(@ps:\x1f:)__tzc_s_nodes[$id]}" )
      [[ ${f[5]} == *P* ]] && hits+=("$id")
    done
    cached=${(pj:\x1d:)hits}
    __tzc_persist_ids[$node]=$cached
  fi
  [[ -n $cached ]] && __tzc_persistent+=(${(ps:\x1d:)cached})
  return 0
}

# walk the spec of command $1; the rest are the complete words after it.
# returns 1 when the command has no spec.
__tzc_add_from_spec() {
  emulate -L zsh
  setopt localoptions noglob
  local cmd=$1
  shift
  local -a words=("$@")
  typeset -A used
  local pending=0 pending_idx=0 arg_index=0 options_done=0
  local word opt_name has_value id count
  local -a reply
  # the words before the typed one stay the same while it is typed, so the
  # walk is kept and a split spec does not reload its root every keystroke
  local wkey="$cmd"$'\x1f'"${#words}"$'\x1f'"${(pj:\x1f:)words}"
  if [[ $wkey == $__tzc_w_key && $__tzc_spec_loaded == $__tzc_w_spec ]]; then
    __tzc_node=${__tzc_w_state[1]}
    pending=${__tzc_w_state[2]}
    pending_idx=${__tzc_w_state[3]}
    arg_index=${__tzc_w_state[4]}
    options_done=${__tzc_w_state[5]}
    used=( "${(@)__tzc_w_used}" )
    __tzc_opt_ids=( "${(@)__tzc_w_opt_ids}" )
  else
    __tzc_spec_load "$cmd" || return 1
    __tzc_node=1
    __tzc_persistent=()
    __tzc_collect_persistent 1
    __tzc_build_opt_ids
    for word in "${words[@]}"; do
      if (( pending )); then
        (( pending_idx++ ))
        __tzc_opt_arg_count "$pending"
        count=$REPLY
        (( pending_idx < count )) || pending=0
        continue
      fi
      if (( ! options_done )) && [[ $word == '--' ]]; then
        options_done=1
        continue
      fi
      if (( ! options_done )) && [[ $word == -?* ]]; then
        opt_name=${word%%=*}
        has_value=0
        [[ $word == *=* ]] && has_value=1
        if __tzc_find_named "$opt_name" "${__tzc_opt_ids[@]}"; then
          id=$REPLY
          used[$id]=1
          if (( ! has_value )) && __tzc_opt_takes_value "$id"; then
            pending=$id
            pending_idx=0
          fi
        fi
        continue
      fi
      if (( arg_index == 0 )); then
        __tzc_ids "$__tzc_node" 9
        if __tzc_find_named "$word" "${reply[@]}"; then
          __tzc_node=$REPLY
          # a split subcommand continues in its own spec, which carries the
          # inherited persistent options
          __tzc_record "$__tzc_node"
          if __tzc_spec_load "$__tzc_spec_loaded/${__tzc_f[2]%%$'\x1d'*}"; then
            __tzc_node=1
            __tzc_persistent=()
            used=()
          fi
          __tzc_collect_persistent "$__tzc_node"
          __tzc_build_opt_ids
          continue
        fi
      fi
      (( arg_index++ ))
    done
    __tzc_w_key=$wkey
    __tzc_w_spec=$__tzc_spec_loaded
    __tzc_w_state=( $__tzc_node $pending $pending_idx $arg_index $options_done )
    __tzc_w_used=( "${(@kv)used}" )
    __tzc_w_opt_ids=( "${(@)__tzc_opt_ids}" )
  fi

  if (( pending )); then
    __tzc_ids "$pending" 10
    (( pending_idx < ${#reply} )) && __tzc_add_arg "${reply[pending_idx+1]}"
    return 0
  fi

  if [[ -n $__tzc_p_option ]]; then
    if __tzc_find_named "$__tzc_p_option" "${__tzc_opt_ids[@]}"; then
      __tzc_ids "$REPLY" 10
      (( ${#reply} )) && __tzc_add_arg "${reply[1]}"
    fi
    return 0
  fi

  if (( ! options_done )) && [[ $__tzc_p_prefix == -* ]]; then
    __tzc_add_nodes option "${__tzc_opt_ids[@]}"
    return 0
  fi

  if (( arg_index == 0 )); then
    __tzc_ids "$__tzc_node" 9
    __tzc_add_nodes subcommand "${reply[@]}"
  fi

  if __tzc_arg_at "$__tzc_node" "$arg_index"; then
    __tzc_add_arg "$REPLY"
  fi
  return 0
}

# sort by score, priority, kind, label; dedupe by insert; cap 200
__tzc_sort_emit() {
  emulate -L zsh
  setopt localoptions noglob
  local -a keys
  local -A seen
  local i key label kind prio score ko insert
  for ((i=1;i<=${#__tzc_c_label};i++)); do
    label=${__tzc_c_label[i]}
    kind=${__tzc_c_kind[i]}
    ko=${__tzc_kind_order[$kind]:-9}
    prio=${__tzc_c_prio[i]}
    score=${__tzc_c_score[i]:-0}
    keys+=("$score${(l:3::0:)$(( 100 - prio ))}${ko}${(L)label}"$'\x1f'"${(l:6::0:)i}")
  done
  # C collation matches python's code-point sort; the locale order ignores
  # punctuation and would put -c before --dereference
  local LC_COLLATE=C
  keys=("${(@o)keys}")
  for key in "${keys[@]}"; do
    i=${key##*$'\x1f'}
    insert=${__tzc_c_insert[i]}
    [[ -n $insert ]] || continue
    (( ${+seen[$insert]} )) && continue
    seen[$insert]=1
    __tzc_candidates+=("${__tzc_c_label[i]}"$'\x1f'"$insert"$'\x1f'"${__tzc_c_desc[i]}"$'\x1f'"${__tzc_c_kind[i]}")
    (( ${#__tzc_candidates} >= 200 )) && break
  done
  return 0
}

__tzc_complete() {
  emulate -L zsh
  setopt localoptions extendedglob
  local buffer=$1 cursor=$2 cwd=$3
  [[ -n $cwd ]] || cwd=$PWD
  __tzc_engine_init
  (( cursor < 0 )) && cursor=0
  (( cursor > ${#buffer} )) && cursor=${#buffer}
  local before=${buffer[1,cursor]}
  __tzc_parse_line "$before"
  __tzc_result_start=$__tzc_p_start
  __tzc_result_end=$cursor
  __tzc_result_typed=${buffer[$(( __tzc_p_start + 1 )),cursor]}
  __tzc_result_line=$before
  __tzc_cwd=$cwd
  __tzc_c_label=()
  __tzc_c_insert=()
  __tzc_c_desc=()
  __tzc_c_kind=()
  __tzc_c_score=()
  __tzc_c_prio=()
  __tzc_candidates=()
  __tzc_hist_candidates=()
  __tzc_add_history
  __tzc_command_words "${__tzc_p_words[@]}"
  if (( __tzc_p_redirect )); then
    __tzc_add_paths 1
  elif (( ${#__tzc_cmd_words} == 0 )); then
    if [[ $__tzc_p_prefix == */* || $__tzc_p_prefix == .* || $__tzc_p_prefix == '~'* ]]; then
      __tzc_add_paths 1
    else
      __tzc_add_commands
    fi
  else
    local command=${__tzc_cmd_words[1]}
    local name=${command##*/}
    if [[ $command != */* ]] && __tzc_add_from_spec "$name" "${(@)__tzc_cmd_words[2,-1]}"; then
      :
    elif [[ $__tzc_p_prefix != -* ]]; then
      __tzc_add_paths 1
    fi
  fi
  __tzc_sort_emit
  return 0
}
