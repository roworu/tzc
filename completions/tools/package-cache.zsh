#!/usr/bin/env zsh
# build plain-text package name/description caches for tzc from local package
# manager data. usage: package-cache.zsh [MANAGER...]

emulate -L zsh
setopt pipe_fail

typeset -g out=${XDG_CACHE_HOME:-$HOME/.cache}/tzc/packages
typeset -ga known=(brew dnf apt pacman zypper apk flatpak)
typeset -ga managers=("${known[@]}")

usage() {
  print -u2 "usage: ${0:t} [MANAGER...]"
  print -u2 "managers: ${(j: :)known}"
  print -u2 "cache directory: $out"
  exit 2
}

(( $# )) && managers=("$@")
managers=( "${(@)managers:/(yum|dnf5)/dnf}" )
for manager in "${managers[@]}"; do
  (( ${known[(Ie)$manager]} )) || { print -u2 "${0:t}: unknown manager: $manager"; usage }
done
mkdir -p -- "$out" || exit 1

fetch_brew() {
  whence -p brew >/dev/null 2>&1 || return 1
  local descs
  # --eval-all lists local formulae and casks without an online search
  descs=$(brew desc --eval-all -s '' 2>/dev/null)
  if [[ -n $descs ]]; then
    print -r -- "$descs" |
      awk '
        /^==> / { next }
        /: / {
          name = $0
          sub(/: .*/, "", name)
          desc = $0
          sub(/^[^:]*: /, "", desc)
          print name "\t" desc
        }
      '
  else
    brew formulae 2>/dev/null
    brew casks 2>/dev/null
  fi
}

fetch_dnf() {
  # -C keeps the query on the local metadata cache
  if whence -p dnf >/dev/null 2>&1; then
    dnf -C -q repoquery --available --qf $'%{name}\t%{summary}\\n'
  elif whence -p repoquery >/dev/null 2>&1; then
    repoquery -C --available --qf $'%{name}\t%{summary}\\n'
  else
    return 1
  fi
}

fetch_apt() {
  whence -p apt-cache >/dev/null 2>&1 || return 1
  apt-cache dumpavail 2>/dev/null |
    awk '
      /^Package: / { name = substr($0, 10) }
      /^Description: / { print name "\t" substr($0, 14) }
    '
}

fetch_pacman() {
  whence -p pacman >/dev/null 2>&1 || return 1
  { pacman -Si 2>/dev/null; pacman -Qi 2>/dev/null; } |
    awk '
      /^Name[[:space:]]*:/ { name = $0; sub(/^Name[[:space:]]*:[[:space:]]*/, "", name) }
      /^Description[[:space:]]*:/ {
        desc = $0
        sub(/^Description[[:space:]]*:[[:space:]]*/, "", desc)
        print name "\t" desc
      }
    '
}

fetch_zypper() {
  whence -p zypper >/dev/null 2>&1 || return 1
  zypper -q --xmlout search -s -t package 2>/dev/null |
    grep -o '<solvable [^>]*>' |
    awk '{
      name = ""; desc = ""
      if (match($0, / name="[^"]*"/)) name = substr($0, RSTART + 7, RLENGTH - 8)
      if (match($0, / summary="[^"]*"/)) desc = substr($0, RSTART + 10, RLENGTH - 11)
      if (name != "") print name "\t" desc
    }'
}

fetch_apk() {
  whence -p apk >/dev/null 2>&1 || return 1
  apk search -q --format $'%n\t%d' 2>/dev/null ||
    apk search -q --format '%n' 2>/dev/null
}

fetch_flatpak() {
  whence -p flatpak >/dev/null 2>&1 || return 1
  flatpak remote-ls --app --columns=application,description 2>/dev/null
}

refresh() {
  local manager=$1
  local tmp="$out/.$manager.$$" sorted="$out/.$manager.$$.sorted"
  if ! "fetch_$manager" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    print -u2 "$manager: skipped (no data)"
    return 1
  fi
  # name<TAB>description, one line per package; descriptions are display text
  LC_ALL=C awk -F $'\t' '
    {
      name = $1
      if (name == "" || name ~ /[[:space:][:cntrl:]]/) next
      desc = $0
      sub(/^[^[:space:]]*[[:space:]]?/, "", desc)
      gsub(/[[:cntrl:]]/, " ", desc)
      sub(/^[[:space:]]+/, "", desc)
      sub(/[[:space:]]+$/, "", desc)
      if (desc == "") print name
      else print name "\t" desc
    }' "$tmp" | LC_ALL=C sort -u > "$sorted" 2>/dev/null || true
  rm -f -- "$tmp"
  if [[ ! -s $sorted ]]; then
    rm -f -- "$sorted"
    print -u2 "$manager: skipped (no packages)"
    return 1
  fi
  mv -f -- "$sorted" "$out/$manager" || { rm -f -- "$sorted"; return 1; }
  print "$manager: $(wc -l < "$out/$manager") packages"
  return 0
}

count=0
for manager in "${managers[@]}"; do
  refresh "$manager" && (( ++count ))
done
(( count )) || exit 1
print "cache directory: $out"
