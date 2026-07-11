#!/usr/bin/env bash
set -e
# Goal-041 structural check: fail if anyone re-adds unconditional std.debug.print to Lib/
if grep -rn 'std\.debug\.print' Lib/ --include='*.zig' | grep -v '// \|test "' > /dev/null 2>&1; then
    echo "FAIL: public library still contains unconditional std.debug.print calls:" >&2
    grep -n 'std\.debug\.print' Lib/ --include='*.zig' >&2
    exit 1
fi
echo "OK: public library is silent (Goal-041) — no unconditional std.debug.print in Lib/"
