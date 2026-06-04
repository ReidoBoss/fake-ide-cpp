#!/bin/sh
# test/run.sh — run the Tier 0 headless smoke test under Vim 8.0.
#
# Usage:  sh test/run.sh            (uses ~/opt/vim80/bin/vim)
#         VIM=/path/to/vim sh test/run.sh
#
# We run Vim inside a pty (script -q /dev/null ...) because Vim's job/channel
# callbacks need a real event loop; plain `-es` does not pump them.
set -e
VIM="${VIM:-$HOME/opt/vim80/bin/vim}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp /tmp/fakeide_smoke.XXXXXX)"

FAKEIDE_SMOKE_OUT="$OUT" TERM=xterm script -q /dev/null \
  "$VIM" -N -u NONE -i NONE -S "$HERE/smoke.vim" >/dev/null 2>&1 || true

echo "== fake-ide Tier 0 smoke ($("$VIM" --version | head -1)) =="
cat "$OUT"
if grep -q '^FAIL' "$OUT"; then
  rm -f "$OUT"
  echo "RESULT: FAIL"
  exit 1
fi
rm -f "$OUT"
echo "RESULT: PASS"
