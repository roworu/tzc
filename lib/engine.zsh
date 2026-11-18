# engine client: requests go to the compcore process started by tzc.zsh, its
# replies become candidate records. history suggestions stay in the shell.

typeset -ga __tzc_candidates __tzc_hist_candidates
# compcore's fds (-1 when it is not running); the last request's seq, line and
# cursor; whether its reply came (done) and is still to be shown (fresh); and
# bytes read that don't end a reply yet
typeset -gi __tzc_eng_in=-1 __tzc_eng_out=-1 __tzc_eng_seq=0
typeset -gi __tzc_eng_done=0 __tzc_eng_fresh=0 __tzc_eng_cursor=0
typeset -g __tzc_eng_buf= __tzc_eng_buffer=

# history suggestions: max entries in the history box; 0 disables. the recent
# window is cached so keystrokes scan an array, not the whole history map.
typeset -g __tzc_history=${TZC_HISTORY:-3}
[[ $__tzc_history == <-> ]] || __tzc_history=3
__tzc_history=$(( 10#$__tzc_history ))
typeset -ga __tzc_hist_lines
typeset -g __tzc_hist_stamp=
# TZC_HISTORY_PWD (default 1): only show history run in the current directory. zsh does
# not store directories, so they are recorded per session by a preexec hook.
typeset -g __tzc_history_pwd=${TZC_HISTORY_PWD:-1}
typeset -gA __tzc_hist_dirs

__tzc_hist_record_dir() {
  __tzc_hist_dirs[$HISTCMD]=$PWD
}
(( __tzc_history_pwd == 1 )) && add-zsh-hook preexec __tzc_hist_record_dir

# rebuild the recent-history window only when the history changes
__tzc_hist_refresh() {
  emulate -L zsh
  setopt localoptions noglob
  # ${#history} is linear on the special parameter, so HISTCMD is the stamp
  local stamp=${HISTCMD:-0}
  (( __tzc_history_pwd == 1 )) && stamp+=$PWD
  [[ $stamp == $__tzc_hist_stamp ]] && return 0
  __tzc_hist_stamp=$stamp
  stamp=${HISTCMD:-0}
  local -a lines
  local key=$(( stamp - 1 ))
  local scans=0 window=500
  while (( key > 0 && scans < window * 2 && ${#lines} < window )); do
    if (( ${+history[$key]} )); then
      (( __tzc_history_pwd == 1 )) && [[ ${__tzc_hist_dirs[$key]} != $PWD ]] ||
        lines+=("${history[$key]}")
    fi
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

# start compcore, the completion engine, as a coprocess. it exits when the
# shell closes its end. without it only history suggestions show.
__tzc_engine_start() {
  emulate -L zsh
  # no job number printed, and no job left for `jobs` or exit warnings
  setopt localoptions nomonitor
  local bin=${TZC_COMPCORE:-${commands[compcore]:-}}
  if [[ -z $bin || ! -x $bin ]]; then
    print -ru2 -- "tzc: compcore not found; put it on PATH or set TZC_COMPCORE"
    return 0
  fi
  local specs=${XDG_CONFIG_HOME:-$HOME/.config}/tzc/specs
  local -a args=(serve)
  [[ -d $specs ]] && args+=(--specs "$specs")
  [[ ${TZC_PROBE_HELP:-1} == 0 ]] && args+=(--no-probe)
  coproc "$bin" "${args[@]}" 2>/dev/null
  exec {__tzc_eng_in}<&p {__tzc_eng_out}>&p
  # job text is unexpanded ("$bin" ...), so match it as the current job
  disown %+ 2>/dev/null
  # close the shell's own p ends, so compcore sees the end when ours close
  coproc exit
  disown %+ 2>/dev/null
  return 0
}

# stop talking to compcore, after it exited or broke the protocol
__tzc_engine_close() {
  emulate -L zsh
  (( __tzc_eng_in >= 0 )) || return 0
  zle -F $__tzc_eng_in 2>/dev/null
  exec {__tzc_eng_in}<&- {__tzc_eng_out}>&- 2>/dev/null
  __tzc_eng_in=-1
  __tzc_eng_out=-1
  return 0
}

# ask compcore for the candidates of $1 at char $2 in folder $3
__tzc_engine_send() {
  emulate -L zsh
  (( __tzc_eng_out >= 0 )) || return 1
  (( __tzc_eng_seq++ ))
  __tzc_eng_buffer=$1
  __tzc_eng_cursor=$2
  __tzc_eng_done=0
  __tzc_eng_fresh=0
  # a nul ends the request, so the line can hold newlines
  print -rn -u $__tzc_eng_out -- \
    "$__tzc_eng_seq"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$PATH"$'\x1f'"$1"$'\0' 2>/dev/null || {
    __tzc_engine_close
    return 1
  }
  return 0
}

# read what compcore wrote. with $1 = block, wait for the reply to the last
# request (compcore answers every newest request); otherwise only take what is
# there, as the zle -F handler does. either way the pipe is drained, so the
# handler doesn't fire again for data left in it. replies to older requests are
# dropped. fails while the last request has no reply.
__tzc_engine_read() {
  emulate -L zsh
  setopt localoptions noglob
  local block=$1 chunk record ret
  local -a wait
  while (( __tzc_eng_in >= 0 )); do
    wait=(-t 0)
    [[ $block == block ]] && (( ! __tzc_eng_done )) && wait=()
    chunk=
    sysread -i $__tzc_eng_in $wait chunk
    ret=$?
    # 4 is nothing left to read, anything else but 0 means compcore is gone
    (( ret == 4 )) && break
    if (( ret )); then
      __tzc_engine_close
      break
    fi
    __tzc_eng_buf+=$chunk
    # compcore writes whole replies, so a buffer ending in nul holds only
    # whole ones. #/% patterns are quadratic on long multibyte text; a split
    # is linear.
    [[ ${__tzc_eng_buf[-1]} == $'\0' ]] || continue
    for record in "${(@ps:\0:)__tzc_eng_buf}"; do
      [[ -n $record ]] && __tzc_engine_take "$record"
    done
    __tzc_eng_buf=
  done
  (( __tzc_eng_done ))
}

# results for line $1 with the cursor at char $2: the word start..end the
# candidates replace, and history entries for the text before the cursor
__tzc_results() {
  emulate -L zsh
  __tzc_result_line=${1[1,$2]}
  __tzc_result_start=$3
  __tzc_result_end=$4
  __tzc_result_typed=${1[$3+1,$4]}
  __tzc_hist_candidates=()
  __tzc_add_history
  return 0
}

# fill the results from a reply: seq start end, then candidate records
__tzc_engine_take() {
  emulate -L zsh
  setopt localoptions noglob
  local -a parts head
  parts=( "${(@ps:\x1e:)1}" )
  head=( "${(@ps:\x1f:)parts[1]}" )
  [[ ${head[1]} == $__tzc_eng_seq ]] || return 0
  __tzc_results "$__tzc_eng_buffer" $__tzc_eng_cursor ${head[2]} ${head[3]}
  __tzc_candidates=( "${(@)parts[2,-1]}" )
  __tzc_eng_done=1
  __tzc_eng_fresh=1
  return 0
}

# ask for the candidates of $1 with the cursor at char $2, in folder $3. the
# reply arrives later through __tzc_engine_read; fails when there is nothing
# to wait for because compcore isn't running, then the results (history only)
# are already set.
__tzc_ask() {
  emulate -L zsh
  local buffer=$1 cursor=$2 cwd=${3:-$PWD}
  (( cursor < 0 )) && cursor=0
  (( cursor > ${#buffer} )) && cursor=${#buffer}
  __tzc_engine_send "$buffer" "$cursor" "$cwd" && return 0
  __tzc_candidates=()
  __tzc_results "$buffer" $cursor 0 $cursor
  return 1
}

# the same, waiting for the reply: for scripts and tests, zle uses __tzc_ask
__tzc_complete() {
  emulate -L zsh
  __tzc_ask "$@" || return 0
  __tzc_engine_read block
  __tzc_eng_fresh=0
  return 0
}
