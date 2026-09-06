#!/bin/bash

# Exercise the real launcher and flock while compositor replies/events are
# controlled. No window or script exists during the first async launch barrier.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command pidof
require_command flock
require_command timeout

tmp=$(mktemp -d)
launcher="$ROOT/bin/omarchy-launch-screensaver"
launcher_pid=""
cleanup() {
  if [[ -n $launcher_pid ]]; then
    kill "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
  fi
  for pid_file in "$tmp"/reader-*.pid; do
    [[ -f $pid_file ]] || continue
    kill "$(<"$pid_file")" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir "$tmp/bin"
mkfifo "$tmp/events"
export OMARCHY_TEST_STATE="$tmp"
export XDG_RUNTIME_DIR="$tmp"
export HYPRLAND_INSTANCE_SIGNATURE="test"
export OMARCHY_PATH="$ROOT"
export PATH="$tmp/bin:$PATH"

cat >"$tmp/bin/hyprctl" <<'SH'
#!/bin/bash
state=${OMARCHY_TEST_STATE:?}
case "$*" in
"clients -j") cat "$state/clients" ;;
"monitors -j") printf '[{"name":"ONE"},{"name":"TWO"}]\n' ;;
*exec_cmd*) printf 'launch\n' >>"$state/launches" ;;
*focus*) printf '%s\n' "$*" >>"$state/focus" ;;
*) exit 99 ;;
esac
SH

cat >"$tmp/bin/socat" <<'SH'
#!/bin/bash
# Stay alive even when the launcher exits, just like an idle event socket.
# This makes an accidentally inherited flock descriptor observable.
exec 3<>"${OMARCHY_TEST_STATE:?}/events"
printf '%s\n' "$$" >"$OMARCHY_TEST_STATE/reader-$$.pid"
while IFS= read -r -u 3 event; do
  printf '%s\n' "$event"
done
SH

cat >"$tmp/bin/omarchy-toggle-enabled" <<'SH'
#!/bin/bash
[[ -f ${OMARCHY_TEST_STATE:?}/disabled ]]
SH
cat >"$tmp/bin/omarchy-hyprland-monitor-focused" <<'SH'
#!/bin/bash
printf 'ORIGINAL\n'
SH
cat >"$tmp/bin/xdg-terminal-exec" <<'SH'
#!/bin/bash
printf 'foot.desktop\n'
SH
chmod +x "$tmp/bin/"*

reset_state() {
  for pid_file in "$tmp"/reader-*.pid; do
    [[ -f $pid_file ]] || continue
    kill "$(<"$pid_file")" 2>/dev/null || true
    rm "$pid_file"
  done
  printf '[]\n' >"$tmp/clients"
  : >"$tmp/launches"
  : >"$tmp/focus"
}

wait_for_launches() {
  local expected="$1"
  for ((attempt = 0; attempt < 150; attempt++)); do
    (($(wc -l <"$tmp/launches") == expected)) && return 0
    sleep 0.01
  done
  fail "launcher reaches async barrier" "expected $expected launches; got $(cat "$tmp/launches")"
}

start_launcher() {
  "$launcher" force >"$tmp/output" 2>&1 &
  launcher_pid=$!
  wait_for_launches 1
}

emit_window() {
  printf '[{"class":"org.omarchy.screensaver"}]\n' >"$tmp/clients"
  printf 'openwindow>>123,1,org.omarchy.screensaver,Screensaver\n' >"$tmp/events"
}

assert_lock_released() {
  flock -n "$tmp/omarchy-screensaver.lock" true ||
    fail "launch lock is released, even with an idle event reader"
}

reset_state
start_launcher
contenders=()
for ((i = 0; i < 8; i++)); do
  timeout 2 "$launcher" force >"$tmp/contender-$i" 2>&1 &
  contenders+=("$!")
done
for contender in "${contenders[@]}"; do
  wait "$contender" || fail "concurrent launch returns promptly"
done
(($(wc -l <"$tmp/launches") == 1)) || fail "concurrent starts dispatch only once"
pass "concurrent starts cannot pass the check-to-map interval"

emit_window
wait_for_launches 2
timeout 2 "$launcher" force || fail "launch during second monitor wait returns promptly"
(($(wc -l <"$tmp/launches") == 2)) || fail "second monitor wait remains serialized"
emit_window
wait "$launcher_pid" || fail "multi-monitor launcher completes"
launcher_pid=""
[[ $(tail -1 "$tmp/focus") == *ORIGINAL* ]] || fail "original monitor focus is restored"
assert_lock_released
pass "one launch per monitor, original focus restored and lock released"

timeout 2 "$launcher" force || fail "mapped screensaver blocks another launch"
(($(wc -l <"$tmp/launches") == 2)) || fail "mapped windows prevent duplicates after lock release"
pass "window gate takes over after the startup lock is released"

reset_state
start_launcher
kill -KILL "$launcher_pid"
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""
assert_lock_released
pass "killed launcher cannot leave its lock held by the event reader"

reset_state
start_launcher
emit_window
wait_for_launches 2
emit_window
wait "$launcher_pid" || fail "relaunch after termination completes"
launcher_pid=""
assert_lock_released
pass "relaunch after termination succeeds"

reset_state
touch "$tmp/disabled"
if "$launcher"; then
  fail "disabled screensaver rejects a normal launch"
fi
[[ ! -s $tmp/launches ]] || fail "disabled screensaver dispatches nothing"
assert_lock_released
start_launcher
emit_window
wait_for_launches 2
emit_window
wait "$launcher_pid" || fail "force bypasses disabled toggle"
launcher_pid=""
assert_lock_released
pass "disabled toggle and force semantics are preserved without stale locks"

reset_state
rm "$tmp/disabled"
timeout 15 "$launcher" force >"$tmp/output" 2>&1 || fail "missing window events do not hang the launcher"
assert_lock_released
pass "window-event timeout releases the startup lock"
