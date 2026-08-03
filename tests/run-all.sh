#!/bin/sh
# Run every hook-script test suite. Exit non-zero if any suite fails.

DIR=$(cd "$(dirname "$0")" && pwd)
FAILED=''

for suite in test-gate.sh test-protect.sh test-provenance.sh; do
    printf '\n'
    sh "$DIR/$suite" || FAILED="$FAILED $suite"
done

printf '\n'
if [ -n "$FAILED" ]; then
    printf 'FAILED suites:%s\n' "$FAILED"
    exit 1
fi
printf 'all suites passed\n'
