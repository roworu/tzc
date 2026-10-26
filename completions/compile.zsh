#!/usr/bin/env zsh
# compile generated specs so first use is cheaper. safe to rerun.
# pass --regenerate to rebuild zsh/*.zsh from json/ first.
emulate -L zsh
set -eu

dir=${${(%):-%x}:A:h}

if (( $# > 1 )) || [[ -n ${1:-} && ${1:-} != --regenerate ]]; then
  print -u2 "usage: $0 [--regenerate]"
  exit 2
fi

if [[ ${1:-} == --regenerate ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    print -u2 "python3 is required to regenerate specs"
    exit 1
  fi
  print "packing $dir/json"
  python3 "$dir/tools/convert.py"
fi

count=0
for file in "$dir"/zsh/**/*.zsh(N); do
  # zcompile writes a read-only .zwc; remove it so reruns can replace it
  rm -f "$file.zwc"
  zcompile "$file"
  (( ++count ))
done

print "compiled $count spec files"
print "use --regenerate after editing completions/json/*.json"
print "and add this to ~/.zshrc :"
print "  source ${dir:h}/tzc.zsh"
