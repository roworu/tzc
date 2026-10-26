# spec blob loading, command index and PATH command cache.

typeset -g __tzc_spec_lib=${${(%):-%x}:A:h}
: ${__tzc_specs_dir:=${__tzc_spec_lib:h}/completions/zsh}
typeset -g __tzc_user_specs=${__tzc_user_specs:-${XDG_CONFIG_HOME:-$HOME/.config}/tzc/specs}

typeset -ga __tzc_s_nodes __tzc_f
typeset -gA __tzc_persist_ids

# shell builtins; `commands` alone misses builtin/eval/export/set
typeset -ga __tzc_builtins
__tzc_builtins=(
  alias bg builtin cd command echo eval exec exit export fg history jobs kill
  popd printf pushd pwd read set source time type unalias unset wait which
)

# load the command -> description map once
__tzc_engine_init() {
  emulate -L zsh
  (( ${+__tzc_index_loaded} )) && return 0
  typeset -gA __tzc_spec_desc
  __tzc_spec_desc=()
  [[ -f $__tzc_specs_dir/index.zsh ]] && source "$__tzc_specs_dir/index.zsh" 2>/dev/null
  [[ -n $__tzc_user_specs && -f $__tzc_user_specs/index.zsh ]] &&
    source "$__tzc_user_specs/index.zsh" 2>/dev/null
  typeset -gi __tzc_index_loaded=1
  return 0
}

# source one spec, "cmd" or a split "cmd/sub", and split its blob into
# records; the first record is the root. a missing or broken file keeps the
# loaded spec.
__tzc_spec_load() {
  emulate -L zsh
  setopt localoptions noglob
  local name=$1 dir file
  [[ $name == $__tzc_spec_loaded ]] && return 0
  for dir in "$__tzc_user_specs" "$__tzc_specs_dir"; do
    [[ -n $dir ]] || continue
    file="$dir/$name.zsh"
    [[ -f $file ]] || continue
    __tzc_s_ok=0
    __tzc_s_blob=
    source "$file" 2>/dev/null || continue
    [[ $__tzc_s_ok == 1 && -n $__tzc_s_blob ]] || continue
    # (p) makes the separator understand \x1e; this is several times faster
    # than an IFS split of the multi-megabyte blob
    __tzc_s_nodes=( ${(ps:\x1e:)__tzc_s_blob} )
    (( ${#__tzc_s_nodes} )) || continue
    __tzc_spec_loaded=$name
    __tzc_persist_ids=()
    return 0
  done
  return 1
}

# split a node record into __tzc_f (kind names desc priority flags template
# suggestions props subs args)
__tzc_record() {
  emulate -L zsh
  setopt localoptions noglob
  # quoted (@) keeps empty fields; (p) makes the separator understand \x1f
  __tzc_f=( "${(@ps:\x1f:)__tzc_s_nodes[$1]}" )
  return 0
}

# PATH commands plus shell builtins, sorted case-insensitively once per
# PATH value. the empty-query command list takes the first 200 of this order.
__tzc_programs() {
  emulate -L zsh
  [[ $__tzc_prog_path == $PATH && ${#__tzc_prog_names} -gt 0 ]] && return 0
  __tzc_prog_path=$PATH
  (( ${+commands} )) || zmodload zsh/parameter 2>/dev/null
  typeset -A seen
  local name
  local -a names keys
  if (( ${+commands} )); then
    rehash 2>/dev/null
    names=( "${(@k)commands}" )
  else
    setopt localoptions extendedglob nullglob
    names=( $^path/*(N-*:t) )
  fi
  for name in "${__tzc_builtins[@]}" "${names[@]}"; do
    # names with whitespace cannot be used as plain assoc keys below
    [[ -n $name && $name != *[[:space:][:cntrl:]]* ]] || continue
    (( ${+seen[$name]} )) && continue
    seen[$name]=1
    keys+=("${(L)name}"$'\x1f'"$name")
  done
  local LC_COLLATE=C
  keys=("${(@o)keys}")
  __tzc_prog_names=( "${(@)keys#*$'\x1f'}" )
  return 0
}
