#!/usr/bin/env bash
# ui.sh — small terminal helpers, sourced by the harness. No output of its own.
#
# Everything degrades: without a TTY the spinner becomes plain lines and the
# pickers return their defaults, so `curl | bash` and CI still work. Interactive
# input is read from /dev/tty, never stdin — when piped from curl, stdin is the
# script itself.

# shellcheck shell=bash

# UI_TTY may be preset by a caller (tests drive the pickers this way);
# otherwise decide from stdout.
if [[ -z "${UI_TTY:-}" ]]; then
  if [[ -t 1 ]]; then UI_TTY=1; else UI_TTY=0; fi
fi

if [[ "$UI_TTY" == 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != dumb ]]; then
  C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_R=$'\033[0m'
  C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YLW=$'\033[33m'; C_CYN=$'\033[36m'
else
  C_DIM=""; C_B=""; C_R=""; C_GRN=""; C_RED=""; C_YLW=""; C_CYN=""
fi

# UI_TTY / TTY_IN are overridable so the pickers can be driven in tests
TTY_IN="${TTY_IN-}"
if [[ -z "$TTY_IN" && -r /dev/tty ]]; then TTY_IN=/dev/tty; fi
ui_interactive() { [[ "$UI_TTY" == 1 && -n "$TTY_IN" ]]; }

# Keystrokes come off one long-lived descriptor rather than reopening the
# device per read — fd 7, to stay clear of the fd 3 usage() borrows.
UI_FD=7
_ui_fd_open=0
_ui_open_input() {
  [[ $_ui_fd_open == 1 ]] && return 0
  exec 7<"$TTY_IN" || return 1
  _ui_fd_open=1
}

ui_title() { printf '\n%s%s%s\n' "$C_B" "$1" "$C_R"; }
ui_note()  { printf '%s%s%s\n' "$C_DIM" "$1" "$C_R"; }
ui_warn()  { printf '%s!%s %s\n' "$C_YLW" "$C_R" "$1" >&2; }

UI_OK=0
UI_FAIL=0
UI_FAILED=()
UI_LOG="${TMPDIR:-/tmp}/harness-$$.log"

ui_log_path() { echo "$UI_LOG"; }

_spin_pid=""
_spin_start() {
  ui_interactive || return 0
  local label=$1
  (
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while :; do
      printf '\r%s%s%s %s' "$C_CYN" "${frames:i++%10:1}" "$C_R" "$label"
      sleep 0.08
    done
  ) &
  _spin_pid=$!
}
_spin_stop() {
  [[ -n "$_spin_pid" ]] || return 0
  kill "$_spin_pid" 2>/dev/null || true
  wait "$_spin_pid" 2>/dev/null || true
  _spin_pid=""
  printf '\r\033[2K'
}
trap '_spin_stop' EXIT INT TERM

# ui_step <label> <cmd...> — run quietly, print one line, keep tallies.
# Output goes to $UI_LOG; only a failure surfaces its tail.
ui_step() {
  local label=$1; shift
  local rc=0 start elapsed steplog
  steplog="$(mktemp)"

  _spin_start "$label"
  start=$SECONDS
  "$@" >"$steplog" 2>&1 </dev/null || rc=$?
  elapsed=$((SECONDS - start))
  _spin_stop
  { echo "### $label"; cat "$steplog"; } >>"$UI_LOG"

  if [[ $rc -eq 0 ]]; then
    UI_OK=$((UI_OK + 1))
    if [[ $elapsed -ge 3 ]]; then
      printf '  %s✓%s %s %s(%ss)%s\n' "$C_GRN" "$C_R" "$label" "$C_DIM" "$elapsed" "$C_R"
    else
      printf '  %s✓%s %s\n' "$C_GRN" "$C_R" "$label"
    fi
  else
    UI_FAIL=$((UI_FAIL + 1))
    UI_FAILED+=("$label")
    printf '  %s✗%s %s\n' "$C_RED" "$C_R" "$label"
    # this step's own tail, not the cumulative log
    grep -v '^$' "$steplog" | tail -n 3 | sed "s/^/      ${C_DIM}/;s/\$/${C_R}/"
    printf '      %sfull log: %s%s\n' "$C_DIM" "$UI_LOG" "$C_R"
  fi
  rm -f "$steplog"
  return 0
}

ui_summary() {
  printf '\n'
  if [[ $UI_FAIL -eq 0 ]]; then
    printf '%s✓%s %s%d installed%s\n' "$C_GRN" "$C_R" "$C_B" "$UI_OK" "$C_R"
  else
    printf '%s✓%s %d installed  %s✗%s %d failed\n' \
      "$C_GRN" "$C_R" "$UI_OK" "$C_RED" "$C_R" "$UI_FAIL"
    printf '    %s%s%s\n' "$C_DIM" "${UI_FAILED[*]}" "$C_R"
    printf '    %slog: %s%s\n' "$C_DIM" "$UI_LOG" "$C_R"
  fi
}

# --- pickers ------------------------------------------------------------
# ui_multiselect <title> <preselect-all:0|1> <item...>
# Items are "value<TAB>label". Chosen values land in UI_PICKED.
# Keys: ↑/↓ or k/j move, space toggles, a all, n none, enter confirm, q abort.
UI_PICKED=()
ui_multiselect() {
  local title=$1 preselect=$2; shift 2
  local items=("$@")
  local n=${#items[@]}
  UI_PICKED=()
  [[ $n -gt 0 ]] || return 0

  local -a on
  local i
  for ((i = 0; i < n; i++)); do on[i]=$preselect; done

  if ! ui_interactive; then
    for ((i = 0; i < n; i++)); do
      [[ ${on[i]} == 1 ]] && UI_PICKED+=("${items[i]%%$'\t'*}")
    done
    return 0
  fi

  local cur=0 drawn=0 key rest
  _draw() {
    [[ $drawn -gt 0 ]] && printf '\033[%dA' "$drawn"
    local j mark ptr label
    for ((j = 0; j < n; j++)); do
      label="${items[j]#*$'\t'}"
      [[ ${on[j]} == 1 ]] && mark="${C_GRN}◉${C_R}" || mark="${C_DIM}◯${C_R}"
      if [[ $j -eq $cur ]]; then ptr="${C_CYN}❯${C_R}"; label="${C_B}${label}${C_R}"
      else ptr=" "; fi
      printf '\033[2K %s %s %s\n' "$ptr" "$mark" "$label"
    done
    printf '\033[2K %s space toggle · a all · n none · ↵ confirm%s\n' "$C_DIM" "$C_R"
    drawn=$((n + 1))
  }

  _ui_open_input || return 1
  printf '\n%s%s%s\n' "$C_B" "$title" "$C_R"
  printf '\033[?25l'
  _draw
  while IFS= read -rsn1 -u "$UI_FD" key; do
    case "$key" in
      $'\e')
        # integer timeout only — bash 3.2 (macOS's /bin/bash) rejects "0.05".
        # Arrow keys arrive as one 3-byte burst, so this never actually waits;
        # the timeout just keeps a lone ESC from blocking forever.
        read -rsn2 -t 1 -u "$UI_FD" rest || rest=""
        case "$rest" in
          '[A') ((cur > 0)) && cur=$((cur - 1)) ;;
          '[B') ((cur < n - 1)) && cur=$((cur + 1)) ;;
        esac
        ;;
      k) ((cur > 0)) && cur=$((cur - 1)) ;;
      j) ((cur < n - 1)) && cur=$((cur + 1)) ;;
      ' ') [[ ${on[cur]} == 1 ]] && on[cur]=0 || on[cur]=1 ;;
      a) for ((i = 0; i < n; i++)); do on[i]=1; done ;;
      n) for ((i = 0; i < n; i++)); do on[i]=0; done ;;
      q) printf '\033[?25h\n'; return 130 ;;
      '') break ;;
    esac
    _draw
  done
  printf '\033[?25h'

  for ((i = 0; i < n; i++)); do
    [[ ${on[i]} == 1 ]] && UI_PICKED+=("${items[i]%%$'\t'*}")
  done
  return 0
}

# ui_confirm <question> <default y|n>
ui_confirm() {
  local q=$1 def=${2:-y} ans
  ui_interactive || { [[ $def == y ]]; return; }
  local hint="[Y/n]"; [[ $def == n ]] && hint="[y/N]"
  _ui_open_input || { [[ $def == y ]]; return; }
  printf '%s %s ' "$q" "$hint"
  read -r -u "$UI_FD" ans || ans=""
  printf '\n'
  ans="${ans:-$def}"
  # not ${ans,,} — that is bash 4+ and macOS ships 3.2
  ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
  [[ "$ans" == y* ]]
}
