#!/bin/bash

# The screensaver launcher must identify an existing screensaver by its exact
# Hyprland window class. Process command lines can collide with unrelated
# programs, while Linux process names are truncated to 15 characters.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

launcher="$ROOT/bin/omarchy-launch-screensaver"
tmp=$(mktemp -d)

cleanup() {
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

if grep -Eq 'pgrep[[:space:]]+(-f|-x)' "$launcher"; then
  fail "launcher no longer relies on process matching for the running check"
fi
pass "launcher no longer relies on process matching for the running check"
