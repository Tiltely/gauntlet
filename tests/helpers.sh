#!/bin/sh
# Minimal test harness for the gauntlet hook scripts. No framework: these are shell
# scripts, so their tests are shell scripts.

PASS=0
FAIL=0
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
export SCRIPTS

# check <name> <expected-substring-or-EMPTY> <actual>
check() {
    _name="$1"
    _want="$2"
    _got="$3"
    if [ "$_want" = "EMPTY" ]; then
        if [ -z "$_got" ]; then
            PASS=$((PASS + 1)); printf '  ok   %s\n' "$_name"; return 0
        fi
    else
        case "$_got" in
            *"$_want"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$_name"; return 0 ;;
        esac
    fi
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$_name" "$_want" "$_got"
    return 1
}

summary() {
    printf '\n%s: %d passed, %d failed\n' "$1" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] || exit 1
}

# A throwaway git repo with one committed source file, so `git diff` has something to say.
make_repo() {
    _r=$(mktemp -d) || exit 1
    mkdir -p "$_r/src/pkg" "$_r/tests/unit/fixtures" "$_r/.claude"
    printf 'x = 1\n' >"$_r/src/pkg/mod.py"
    printf 'def test_x(): assert True\n' >"$_r/tests/unit/test_mod.py"
    git -C "$_r" init -q 2>/dev/null
    git -C "$_r" add -A 2>/dev/null
    git -C "$_r" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
    printf '%s' "$_r"
}

# write_manifest <repo> <fast-command>
write_manifest() {
    cat >"$1/.claude/gauntlet.json" <<EOF
{
  "fast": "$2",
  "full": "true",
  "sourcePatterns": ["src/**/*.py"],
  "fixturePatterns": ["tests/**/fixtures/**"]
}
EOF
}

# stop_payload <cwd> <session> [tool-names...]
stop_payload() {
    _cwd="$1"; _sess="$2"; shift 2
    _calls=''
    for _t in "$@"; do
        _calls="$_calls{\"tool_name\":\"$_t\",\"tool_use_id\":\"u\"},"
    done
    _calls=$(printf '%s' "$_calls" | sed 's/,$//')
    printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","tool_calls":[%s]}' \
        "$_sess" "$_cwd" "$_calls"
}

# pretooluse_payload <tool> <json-tool-input> [cwd] [session]
#
# The session defaults to a per-RUN value, not a per-case one: the challenge marks and the
# ledger live in TMPDIR and outlive the process, so a fixed default would make the second run
# of the suite disagree with the first — the "first attempt is denied" cases would come back
# as already-affirmed.
pretooluse_payload() {
    printf '{"hook_event_name":"PreToolUse","session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":%s}' \
        "${4:-$(new_session default)}" "${3:-$(pwd)}" "$1" "$2"
}

# The ledger file protect.sh writes for a given session, so a test can assert on it.
ledger_of() {
    printf '%s/gauntlet-ledger-%s' "${TMPDIR:-/tmp}" \
        "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_')"
}

# Retry counters are keyed on session_id; a fresh one per case keeps cases independent.
new_session() {
    printf 'sess-%s-%s' "$$" "$1"
}
