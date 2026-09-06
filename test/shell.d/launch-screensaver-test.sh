#!/bin/bash

# The screensaver launcher must identify an existing screensaver by its exact
# Hyprland window class or real script process. Run jq, pidof and flock, not
# substitutes: argv decoys and Linux comm truncation caused the original bug.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command pidof
require_command flock

launcher="$ROOT/bin/omarchy-launch-screensaver"
tmp=$(mktemp -d)

process_pid=""
cleanup() {
  if [[ -n $process_pid ]]; then
    kill "$process_pid" 2>/dev/null || true
    wait "$process_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

cat >"$tmp/hyprctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"${OMARCHY_TEST_HYPRCTL_LOG:?}"

if [[ $1 == clients && $2 == -j ]]; then
  printf '%s\n' "${OMARCHY_TEST_CLIENTS_JSON:?}"
  exit 0
fi

printf 'unexpected hyprctl call: %s\n' "$*" >&2
exit 99
SH
chmod +x "$tmp/hyprctl"

cat >"$tmp/omarchy-toggle-enabled" <<'SH'
#!/bin/bash
printf 'toggle\n' >>"${OMARCHY_TEST_HELPER_LOG:?}"
exit 1
SH
chmod +x "$tmp/omarchy-toggle-enabled"

cat >"$tmp/omarchy-hyprland-monitor-focused" <<'SH'
#!/bin/bash
printf 'focused\n' >>"${OMARCHY_TEST_HELPER_LOG:?}"
printf 'MONITOR\n'
SH
chmod +x "$tmp/omarchy-hyprland-monitor-focused"

cat >"$tmp/xdg-terminal-exec" <<'SH'
#!/bin/bash
printf 'terminal\n' >>"${OMARCHY_TEST_HELPER_LOG:?}"
printf 'UnsupportedTerminal\n'
SH
chmod +x "$tmp/xdg-terminal-exec"

cat >"$tmp/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notification\n' >>"${OMARCHY_TEST_HELPER_LOG:?}"
exit 0
SH
chmod +x "$tmp/omarchy-notification-send"

hyprctl_log="$tmp/hyprctl.log"
helper_log="$tmp/helper.log"

run_launcher() {
  local clients_json="$1"

  : >"$hyprctl_log"
  : >"$helper_log"
  OMARCHY_TEST_CLIENTS_JSON="$clients_json" \
    OMARCHY_TEST_HYPRCTL_LOG="$hyprctl_log" \
    OMARCHY_TEST_HELPER_LOG="$helper_log" \
    XDG_RUNTIME_DIR="$tmp" \
    PATH="$tmp:$PATH" \
    "$launcher" 2>&1
}

assert_existing_screensaver_exits_early() {
  local clients_json="$1"
  local description="$2"
  local output rc

  set +e
  output=$(run_launcher "$clients_json")
  rc=$?
  set -e

  ((rc == 0)) || fail "$description" "rc=$rc output=$output"
  [[ $(<"$hyprctl_log") == "clients -j" ]] ||
    fail "$description" "unexpected hyprctl calls: $(<"$hyprctl_log")"
  [[ ! -s $helper_log ]] ||
    fail "$description" "launcher continued after the window gate: $(<"$helper_log")"
  pass "$description"
}

assert_existing_screensaver_exits_early \
  '[{"class":"org.omarchy.screensaver","initialClass":"foot"}]' \
  "current screensaver class prevents a duplicate launch"

assert_existing_screensaver_exits_early \
  '[{"class":"foot","initialClass":"org.omarchy.screensaver"}]' \
  "initial screensaver class prevents a duplicate launch"

# A public app-id string outside the exact class fields must not trigger the
# gate. The unsupported terminal stops the launcher safely after that proof.
set +e
output=$(run_launcher '[{"class":"org.omarchy.screensaver-helper","initialClass":"foot","title":"org.omarchy.screensaver"}]')
rc=$?
set -e

((rc == 1)) || fail "non-matching clients continue past the window gate" "rc=$rc output=$output"
[[ $(<"$helper_log") == $'toggle\nfocused\nterminal\nnotification' ]] ||
  fail "non-matching clients continue past the window gate" "helper calls: $(<"$helper_log")"
pass "non-matching clients continue past the window gate"

# Use a real bash script with the long filename, not a stubbed process finder.
# Blocking on a FIFO keeps the script itself alive without orphan sleep jobs.
mkfifo "$tmp/process-input"
cat >"$tmp/omarchy-screensaver" <<'SH'
#!/bin/bash
exec 3<>"${OMARCHY_TEST_PROCESS_INPUT:?}"
printf 'ready\n' >"${OMARCHY_TEST_PROCESS_READY:?}"
read -r -u 3
SH
chmod +x "$tmp/omarchy-screensaver"

start_process() {
  local script="$1"
  shift
  rm -f "$tmp/process-ready"
  OMARCHY_TEST_PROCESS_INPUT="$tmp/process-input" \
    OMARCHY_TEST_PROCESS_READY="$tmp/process-ready" "$script" "$@" &
  process_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -s $tmp/process-ready ]] && return 0
    sleep 0.02
  done
  fail "real process fixture starts"
}

cp "$tmp/omarchy-screensaver" "$tmp/decoy"
start_process "$tmp/decoy" org.omarchy.screensaver omarchy-screensaver
set +e
output=$(run_launcher '[]')
rc=$?
set -e
((rc == 1)) && [[ $(<"$helper_log") == $'toggle\nfocused\nterminal\nnotification' ]] ||
  fail "real argv decoy does not block launching" "rc=$rc output=$output"
pass "real argv decoy does not block launching"
kill "$process_pid"
wait "$process_pid" 2>/dev/null || true
process_pid=""

start_process "$tmp/omarchy-screensaver"
assert_existing_screensaver_exits_early '[]' \
  "real bash screensaver blocks launching before any window maps"
kill "$process_pid"
wait "$process_pid" 2>/dev/null || true
process_pid=""

set +e
output=$(run_launcher '[]')
rc=$?
set -e
((rc == 1)) && [[ -s $helper_log ]] ||
  fail "exited screensaver does not leave a stale process or lock gate" "rc=$rc output=$output"
pass "exited screensaver does not leave a stale process or lock gate"
