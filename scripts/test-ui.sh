#!/usr/bin/env bash
# test-ui.sh — drive the pickers without a terminal.
#
# ui.sh reads keystrokes from $TTY_IN off a persistent fd, so a plain file of
# bytes stands in for a tty. Guards against the two bash-4-isms that broke this
# on macOS's stock bash 3.2: fractional `read -t` and ${var,,}.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
chk() {
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s (got %q want %q)\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}

sel() { # <keys> <preselect>
  local f; f="$(mktemp)"; printf '%b' "$1" >"$f"
  UI_TTY=1 TTY_IN="$f" bash -c '
    source scripts/ui.sh
    ui_multiselect "T" '"$2"' $'"'"'a\tAlpha'"'"' $'"'"'b\tBravo'"'"' $'"'"'c\tCharlie'"'"' \
      >/dev/null 2>&1
    echo "${UI_PICKED[*]:-<none>}"'
  rm -f "$f"
}

cfm() { # <keys> <default>
  local f; f="$(mktemp)"; printf '%b' "$1" >"$f"
  UI_TTY=1 TTY_IN="$f" bash -c \
    'source scripts/ui.sh; ui_confirm "go?" '"$2"' >/dev/null 2>&1 && echo yes || echo no'
  rm -f "$f"
}

echo "multiselect ($(bash --version | head -1 | sed 's/.*version //;s/ .*//'))"
chk "space toggles"          "$(sel ' \n' 0)"             "a"
chk "j moves down"           "$(sel 'j \n' 0)"            "b"
chk "arrow down x2"          "$(sel '\033[B\033[B \n' 0)" "c"
chk "arrow up clamps at top" "$(sel '\033[A \n' 0)"       "a"
chk "arrow down then up"     "$(sel '\033[B\033[A \n' 0)" "a"
chk "a selects all"          "$(sel 'a\n' 0)"             "a b c"
chk "n clears all"           "$(sel 'n\n' 1)"             "<none>"
chk "preselected pass thru"  "$(sel '\n' 1)"              "a b c"
chk "toggle one off"         "$(sel 'j \n' 1)"            "a c"
chk "q aborts empty"         "$(sel 'q' 0)"               "<none>"

echo "confirm"
chk "explicit yes"    "$(cfm 'Y\n' y)" "yes"
chk "empty takes def" "$(cfm '\n' y)"  "yes"
chk "explicit no"     "$(cfm 'n\n' y)" "no"

echo "non-interactive"
chk "picker returns defaults" \
  "$(UI_TTY=0 TTY_IN= bash -c 'source scripts/ui.sh
     ui_multiselect T 1 $'"'"'a\tA'"'"' $'"'"'b\tB'"'"' >/dev/null 2>&1
     echo "${UI_PICKED[*]}"')" "a b"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
