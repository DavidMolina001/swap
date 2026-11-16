#!/bin/zsh
# Live self-test: builds a test copy with -D SELFTEST, opens 3 TextEdit windows and 1 Preview window
# and drives Swap with real Option+Tab keystrokes and trackpad swipes (about 2 minutes). Keep hands off
# the keyboard and trackpad while it runs. It only switches between its own TextEdit, Preview and helper
# windows. With 2+ desktops it also opens a helper window on Desktop 2 (Control+Right/Left must be on).
# The process that runs this script needs Accessibility (System Settings > Privacy & Security).
set -e
cd "$(dirname "$0")"
T="$(mktemp -d)"
swiftc -O -swift-version 5 -D SELFTEST -target "$(uname -m)-apple-macos13" *.swift -o "$T/Swap"
swiftc -O -swift-version 5 TestWindow/SwapTestWindow.swift -o "$T/SwapTestWindow"
start=$("$T/SwapTestWindow" desk)
while [[ $("$T/SwapTestWindow" desk) -gt 0 ]]; do "$T/SwapTestWindow" key left; sleep 1.2; done
for n in One Two Three; do echo "Swap test window $n" > "$T/Swap test $n.txt"; done
cp ../screenshots/panel.png "$T/Swap test picture.png"
open -a TextEdit "$T/Swap test One.txt" "$T/Swap test Two.txt" "$T/Swap test Three.txt"
open -a Preview "$T/Swap test picture.png"; sleep 3
SWAP_TEST_HELPER="$T/SwapTestWindow" SWAP_ONLY_APP=com.apple.TextEdit,com.apple.Preview,SwapTestWindow "$T/Swap" --selftest "$T/selftest.log" >/dev/null 2>&1 &
for i in {1..180}; do sleep 1; grep -q "^DONE" "$T/selftest.log" 2>/dev/null && break; done
osascript -e 'tell application "TextEdit" to close (every document whose name starts with "Swap test") saving no' \
  -e 'tell application "Preview" to close (every window whose name starts with "Swap test")' >/dev/null 2>&1 || true
pkill -x SwapTestWindow 2>/dev/null || true
while [[ $("$T/SwapTestWindow" desk) -lt $start ]]; do "$T/SwapTestWindow" key right; sleep 1.2; done
cat "$T/selftest.log"
grep -q "^DONE all passed" "$T/selftest.log"
