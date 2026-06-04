#!/bin/sh
# test/run.sh — run the fake-ide headless tests under Vim 8.0.
#
# Usage:  sh test/run.sh            (uses ~/opt/vim80/bin/vim)
#         VIM=/path/to/vim sh test/run.sh
#
# Each test script writes PASS/FAIL lines to the file named in
# $FAKEIDE_SMOKE_OUT. We run Vim inside a pty (script -q /dev/null ...) because
# Vim's job/channel callbacks need a real event loop; plain `-es` does not pump
# them. On macOS `script` is `script [-q] file command...`; on Linux it is
# `script -q -c "command" file` — we detect which.
set -e
VIM="${VIM:-$HOME/opt/vim80/bin/vim}"
HERE="$(cd "$(dirname "$0")" && pwd)"

run_in_pty() {
  # $1 = vim args (single string). Runs under a pty, output discarded.
  if script -q /dev/null true >/dev/null 2>&1; then
    # BSD/macOS: script -q <file> <command...>
    # shellcheck disable=SC2086
    script -q /dev/null $1 >/dev/null 2>&1 || true
  else
    # util-linux: script -q -c "<command>" <file>
    script -q -c "$1" /dev/null >/dev/null 2>&1 || true
  fi
}

FAIL=0
echo "== fake-ide tests ($("$VIM" --version | head -1)) =="
for t in smoke diag complete; do
  OUT="$(mktemp /tmp/fakeide_${t}.XXXXXX)"
  FAKEIDE_SMOKE_OUT="$OUT" TERM=xterm \
    run_in_pty "$VIM -N -u NONE -i NONE -S $HERE/$t.vim"
  echo "--- $t.vim ---"
  cat "$OUT"
  if grep -q '^FAIL' "$OUT"; then
    FAIL=1
  fi
  rm -f "$OUT"
done

if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
