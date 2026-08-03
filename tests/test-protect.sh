#!/bin/sh
# Tests for the artefact-protection hook. One case per row of protect.sh's tables, plus
# the false-positive cases: an ordinary code edit and a cache cleanup must pass untouched,
# or the guard becomes noise the user learns to click through.

. "$(dirname "$0")/helpers.sh"

printf 'protect.sh\n'

R=$(make_repo)
write_manifest "$R" "true"

edit() { # edit <file> <old> <new>
    pretooluse_payload Edit "$(jq -n --arg f "$1" --arg o "$2" --arg n "$3" \
        '{file_path:$f, old_string:$o, new_string:$n}')" "$R" | sh "$SCRIPTS/protect.sh"
}
write() { # write <file> <content>
    pretooluse_payload Write "$(jq -n --arg f "$1" --arg c "$2" '{file_path:$f, content:$c}')" "$R" |
        sh "$SCRIPTS/protect.sh"
}
bash_cmd() {
    pretooluse_payload Bash "$(jq -n --arg c "$1" '{command:$c}')" "$R" | sh "$SCRIPTS/protect.sh"
}

# --- protected paths -------------------------------------------------------------------
check "pyproject.toml -> ask" '"permissionDecision": "ask"' "$(edit "$R/pyproject.toml" a b)"
check "manifest -> ask" '"permissionDecision": "ask"' "$(edit "$R/.claude/gauntlet.json" a b)"
check "settings.json -> ask" '"permissionDecision": "ask"' "$(edit "$HOME/.claude/settings.json" a b)"
check "Justfile -> ask" '"permissionDecision": "ask"' "$(edit "$R/Justfile" a b)"
check "ruff.toml -> ask" '"permissionDecision": "ask"' "$(edit "$R/ruff.toml" a b)"
check ".coveragerc -> ask" '"permissionDecision": "ask"' "$(edit "$R/.coveragerc.testcov" a b)"
check "workflow -> ask" '"permissionDecision": "ask"' "$(edit "$R/.github/workflows/ci.yml" a b)"
check "package.json -> ask" '"permissionDecision": "ask"' "$(edit "$R/package.json" a b)"
check "jest.config.ts -> ask" '"permissionDecision": "ask"' "$(edit "$R/jest.config.ts" a b)"
check "tsconfig.json -> ask" '"permissionDecision": "ask"' "$(edit "$R/tsconfig.json" a b)"
check "plugin's own scripts -> ask" '"permissionDecision": "ask"' \
    "$(edit "/x/gauntlet/scripts/gate.sh" a b)"

# --- ordinary edits must stay silent ---------------------------------------------------
check "normal source edit -> silent" EMPTY "$(edit "$R/src/pkg/mod.py" 'x = 1' 'x = 2')"
check "normal test edit -> silent" EMPTY \
    "$(edit "$R/tests/unit/test_mod.py" 'assert True' 'assert 1 == 1')"
check "README -> silent" EMPTY "$(edit "$R/README.md" a b)"

# --- loosening markers: deny, not ask --------------------------------------------------
# `deny` because there is no common legitimate version of these, and because a hook's `ask`
# is resolved by the auto-mode classifier and may never reach the user. A guard that silently
# self-approves produces confidence without protection.
#
# The marker strings are ASSEMBLED here rather than written literally, so this file does not
# itself trip the hook it tests. That is not a trick to route around the guard — it is the
# same distinction the guard now makes: a marker only counts in a language where it does
# something, and this is a shell script.
TYPE_IGNORE="# type: $(printf 'ignore')"
NO_COVER="# pragma: no $(printf 'cover')"

check "adds a type suppression -> deny" '"permissionDecision": "deny"' \
    "$(edit "$R/src/pkg/mod.py" 'x = f()' "x = f()  $TYPE_IGNORE")"
check "adds a coverage suppression -> deny" '"permissionDecision": "deny"' \
    "$(edit "$R/src/pkg/mod.py" 'def g():' "def g():  $NO_COVER")"
check "adds a pytest skip -> deny" '"permissionDecision": "deny"' \
    "$(edit "$R/tests/unit/test_mod.py" 'def test_x():' '@pytest.mark.skip
def test_x():')"
check "adds a suite skip -> deny" '"permissionDecision": "deny"' \
    "$(edit "$R/src/a.test.ts" 'describe(' 'describe.skip(')"
check "adds a ts suppression -> deny" '"permissionDecision": "deny"' \
    "$(edit "$R/src/a.ts" 'const x = y' '// @ts-'"$(printf 'ignore')"'
const x = y')"
check "adds a lint suppression -> deny" '"permissionDecision": "deny"' \
    "$(edit "$R/src/a.ts" 'const x = y' '/* eslint-'"$(printf 'disable')"' */
const x = y')"

# --- moving a coverage threshold -------------------------------------------------------
# The keyword is present on BOTH sides and only the number moves, so the marker loop cannot
# see this one — it needs its own value comparison.
HIGH="fail_$(printf 'under') = 100"
LOW="fail_$(printf 'under') = 80"
check "lowering the coverage floor -> deny" '"permissionDecision": "deny"' \
    "$(edit "$R/setup.cfg" "$HIGH" "$LOW")"
check "unchanged floor -> silent" EMPTY \
    "$(edit "$R/src/pkg/mod.py" "x = 1  # $HIGH" "y = 2  # $HIGH")"

# --- a marker only counts where it does something ---------------------------------------
# Not hypothetical: earlier versions of this hook blocked edits to its OWN tests and README,
# because a guard's tests necessarily contain every pattern the guard matches on.
check "suppression in markdown -> silent" EMPTY \
    "$(edit "$R/README.md" 'use it' "use it, e.g. \`$TYPE_IGNORE\`")"
check "suppression in a shell script -> silent" EMPTY \
    "$(edit "$R/scripts/deploy.sh" 'echo hi' "echo hi  $TYPE_IGNORE")"

# An existing marker that merely survives an unrelated edit is not a new suppression.
check "keeps existing marker -> silent" EMPTY \
    "$(edit "$R/src/pkg/mod.py" 'x = f()  # type: ignore' 'x = g()  # type: ignore')"
check "removes a marker -> silent" EMPTY \
    "$(edit "$R/src/pkg/mod.py" 'x = f()  # type: ignore' 'x = f()')"

# --- gutting a test file ---------------------------------------------------------------
BIG=$(awk 'BEGIN{for(i=0;i<40;i++) print "def test_" i "(): assert compute(" i ") == " i}')
printf '%s\n' "$BIG" >"$R/tests/unit/test_big.py"
check "gutting a test file -> deny" '"permissionDecision": "deny"' \
    "$(write "$R/tests/unit/test_big.py" 'def test_one(): assert True')"
check "growing a test file -> silent" EMPTY \
    "$(write "$R/tests/unit/test_big.py" "$BIG
def test_extra(): assert compute(99) == 99")"
check "new test file -> silent" EMPTY \
    "$(write "$R/tests/unit/test_new.py" 'def test_y(): assert True')"

# --- Bash back doors -------------------------------------------------------------------
check "deleting a test -> deny" '"permissionDecision": "deny"' "$(bash_cmd 'rm tests/unit/test_mod.py')"
check "deleting a test dir -> deny" '"permissionDecision": "deny"' "$(bash_cmd 'rm -rf tests/unit')"
check "bypassing the hooks -> deny" '"permissionDecision": "deny"' \
    "$(bash_cmd 'git commit --no-verify -m x')"
check "uninstalling a checker -> deny" '"permissionDecision": "deny"' \
    "$(bash_cmd 'uv remove --dev pytest-cov')"
# Only in command position: the same words as DATA inside a grep pattern or heredoc must pass.
check "the words as data -> silent" EMPTY \
    "$(bash_cmd "grep -nE 'rm of a test|--no-verify' tests/test-protect.sh")"
check "git checkout of tests -> ask" '"permissionDecision": "ask"' \
    "$(bash_cmd 'git checkout -- tests/unit/test_mod.py')"
check "sed -i on pyproject -> ask" '"permissionDecision": "ask"' \
    "$(bash_cmd "sed -i '' 's/fail_under = 100/fail_under = 0/' pyproject.toml")"
check "clearing pytest cache -> silent" EMPTY "$(bash_cmd 'rm -rf .pytest_cache')"
check "running the tests -> silent" EMPTY "$(bash_cmd 'uv run pytest tests/unit -v')"
check "plain ls -> silent" EMPTY "$(bash_cmd 'ls -la src')"

# --- safeguards ------------------------------------------------------------------------
check "GAUNTLET=off -> silent" EMPTY \
    "$(pretooluse_payload Edit '{"file_path":"/x/pyproject.toml"}' "$R" |
        GAUNTLET=off sh "$SCRIPTS/protect.sh")"

# The plugin's own repo is exempt: a guard's tests contain every pattern the guard matches, so
# with the guard live its own development is impossible.
OWN=$(mktemp -d)
mkdir -p "$OWN/.claude-plugin"
printf '{"name":"gauntlet","version":"0.0.0"}\n' >"$OWN/.claude-plugin/plugin.json"
git -C "$OWN" init -q 2>/dev/null
check "own repo is exempt" EMPTY \
    "$(pretooluse_payload Edit "$(jq -n --arg f "$OWN/pyproject.toml" \
        '{file_path:$f, old_string:"a", new_string:"b"}')" "$OWN" | sh "$SCRIPTS/protect.sh")"
printf '{"name":"other-plugin","version":"0.0.0"}\n' >"$OWN/.claude-plugin/plugin.json"
check "another plugin repo is NOT exempt" '"permissionDecision": "ask"' \
    "$(pretooluse_payload Edit "$(jq -n --arg f "$OWN/pyproject.toml" \
        '{file_path:$f, old_string:"a", new_string:"b"}')" "$OWN" | sh "$SCRIPTS/protect.sh")"
rm -rf "$OWN"
check "garbage payload -> silent" EMPTY "$(printf 'nonsense' | sh "$SCRIPTS/protect.sh")"
check "empty payload -> silent" EMPTY "$(printf '' | sh "$SCRIPTS/protect.sh")"
check "no file_path -> silent" EMPTY \
    "$(pretooluse_payload Edit '{"old_string":"a"}' "$R" | sh "$SCRIPTS/protect.sh")"

rm -rf "$R"
summary protect.sh
