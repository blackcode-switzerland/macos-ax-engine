#!/bin/bash
# The test kit: one command.
#
#   curl -fsSL https://raw.githubusercontent.com/blackcode-switzerland/macos-ax-engine/main/kit.sh | bash
#
# What it does, in order:
#   1. fetches the source of this repository into a temporary folder,
#   2. builds it on this Mac with Apple's Swift compiler (nothing is downloaded
#      as a program, so macOS has nothing to block and no notarisation is needed),
#   3. starts a small test program and runs the checks against it,
#   4. prints a pass/fail table,
#   5. packs the logs into ONE file in the folder you ran it from.
#
# What it touches: the temporary folder, the test program it starts itself, and
# TextEdit only if TextEdit is not already open. It takes no picture of the
# screen and reads no other program. The logs hold the check results, the
# controls of the test program, and the macOS version and chip type.
#
# Needs: the Accessibility permission for the program you run this from
# (Terminal: System Settings > Privacy & Security > Accessibility), and Apple's
# command-line developer tools (xcode-select --install).
#
# Settings (environment): KIT_REF = branch, tag or commit to test (default main).
set -uo pipefail

repo="blackcode-switzerland/macos-ax-engine"
ref="${KIT_REF:-main}"
start_dir="$PWD"
stamp="$(date +%Y%m%d-%H%M%S)"

say() { printf '%s\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  say "This kit runs on macOS only."; exit 2
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  say "Apple's command-line developer tools are missing."
  say "Install them with:  xcode-select --install   and run this command again."
  exit 2
fi

work="$(mktemp -d /tmp/ax-kit.XXXXXX)" || { say "could not create a temporary folder"; exit 2; }
logs="$work/logs"
mkdir -p "$logs"

{
  say "kit ref: $ref"
  say "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sw_vers
  say "chip: $(uname -m)"
  say "swift: $(xcrun swiftc --version 2>&1 | head -1)"
  say "started from: ${TERM_PROGRAM:-unknown}"
} > "$logs/system.txt" 2>&1

say "1/4 fetching source ($ref)"
if ! curl -fsSL "https://github.com/$repo/archive/$ref.tar.gz" | tar -xz -C "$work" --strip-components 1 -f - 2> "$logs/fetch.txt"; then
  say "Could not fetch the source. See $logs/fetch.txt"; exit 2
fi

say "2/4 building"
if ! bash "$work/scripts/build.sh" > "$logs/build.txt" 2>&1; then
  say "The build failed:"; tail -20 "$logs/build.txt"
  status=2
else
  say "3/4 running the checks (a small window named 'AX Fixture' appears for a few seconds)"
  "$work/build/axprobe" trial --fixture "$work/build/axfixture" --out "$logs/direct" --mode kit --textedit 2>&1 | tee "$logs/run.txt"
  status=${PIPESTATUS[0]}
  if [ "$status" -eq 0 ]; then
    say ""
    say "    now the tools of the engine, the same way an agent would use them"
    /usr/bin/env python3 "$work/tests/mcp_test.py" "$work/build/axengine" "$work/build/axfixture" "$logs/engine" 2>&1 | tee "$logs/engine-run.txt"
    status=${PIPESTATUS[0]}
  fi
fi

say ""
say "4/4 packing the logs"
pack="$start_dir/ax-kit-logs-$stamp.tgz"
if tar -czf "$pack" -C "$work" logs; then
  say "Logs: $pack"
  say "Please send this one file back."
else
  say "Could not pack the logs; they are in $logs"
fi

case "$status" in
  0) say "RESULT: PASS" ;;
  2) say "RESULT: COULD NOT RUN" ;;
  *) say "RESULT: FAIL (see the table above)" ;;
esac
rm -rf "$work/build" 2>/dev/null
exit "$status"
