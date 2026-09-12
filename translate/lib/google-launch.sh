#!/usr/bin/env bash
# All user data arrives as positional arguments or through a UTF-8 input file.
command -v gawk >/dev/null && command -v cygpath >/dev/null || {
    printf '%s\n' 'Google mode requires Git Bash with gawk and cygpath' >&2
    exit 127
}
script=$(cygpath -u "$1") || exit 1
input=$(cygpath -u "$2") || exit 1
exec bash --noprofile --norc "$script" -engine google -brief -no-ansi -no-init -source auto -target "$3" -input "$input"
