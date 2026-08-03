#!/bin/sh
# gauntlet — PreToolUse hook: the agent cannot loosen the gate on its own.
#
# This is the hook that makes the others mean anything. Without it the design is theatre:
# the agent has write access to the tests, the coverage config, the linter config, the
# manifest and the workflows, so a blocked turn has a shortcut — skip the test, ignore the
# type, drop the coverage floor, delete the file. A prisoner who can edit the bars is not held.
#
# Two verdicts, and the split is load-bearing:
#
#   deny — changes that ONLY make sense to weaken the gate: adding a suppression marker,
#          moving a coverage threshold, gutting or deleting a test, `--no-verify`,
#          uninstalling a checker. There is no common legitimate version of these.
#
#   ask  — editing a gate config file for any OTHER reason. pyproject.toml and package.json
#          have a thousand honest uses and this hook cannot tell who asked for the change,
#          so it escalates instead of blocking.
#
# Why not `ask` for everything (the original design): under `defaultMode: "auto"` with
# `skipAutoPermissionPrompt`, a hook's `ask` is resolved by the auto classifier and may never
# reach the user, while `deny` always lands. An `ask` that silently self-approves is worse
# than no guard — confidence without protection is the exact failure this plugin exists to
# prevent. So the dangerous subset does not depend on it.
#
# Order matters: every `deny` rule is evaluated BEFORE the `ask` rule, or lowering the
# coverage floor inside pyproject.toml would exit as a mere `ask` on the file path.
#
# The protected list lives HERE, in the plugin, not in .claude/gauntlet.json —
# a configurable guard is a removable guard.

. "$(dirname "$0")/common.sh"

gauntlet_is_off && exit 0

INPUT=$(gauntlet_read_input)
[ -n "$INPUT" ] || exit 0
gauntlet_debug_dump "$INPUT" "PreToolUse"
gauntlet_require_jq || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Developing the guard itself is exempt — see gauntlet_is_own_repo for why this is structural
# and not a convenience.
#
# For Write/Edit the target FILE decides (checked below, once the path is known). For Bash the
# payload's cwd is all there is, and it does NOT reflect a `cd` inside the command — so a
# `sed`/`grep` over the plugin's own tests from another cwd still trips the guard. Accepted
# gap: use GAUNTLET=off for that, or edit the file with Edit instead of a shell one-liner.
gauntlet_is_own_repo "$(gauntlet_root "$INPUT")" && exit 0

# --- Bash: the back door around a Write/Edit guard -------------------------------------
# Blocking edits to a test file is pointless if `rm` still works.
#
# Every pattern anchors the dangerous token to COMMAND POSITION — start of string, or right
# after `;`, `&&`, `||`, `|`, or a newline. Matching anywhere fires on the same words
# appearing as DATA: a heredoc, a grep pattern, a commit message that merely mentions
# `--no-verify`. Found the hard way — an early version blocked the edit to its own test file
# because that file's text contained the phrase.
#
# ponytail: positional anchoring, not shell parsing. `echo x; rm tests/a.py` is caught,
# `sh -c "rm tests/a.py"` is not. Real parsing is the upgrade path if that gap ever matters.
if [ "$TOOL" = "Bash" ]; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$CMD" ] || exit 0
    CMDPOS='(^|[;&|]|&&|\|\||\n)[[:space:]]*'

    if printf '%s' "$CMD" | grep -qE \
        "${CMDPOS}(rm|unlink)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^;&|]*(test|spec|fixture)" \
        2>/dev/null &&
        ! printf '%s' "$CMD" | grep -qE '(_cache|\.cache|node_modules|__pycache__|\.tox|coverage)' \
            2>/dev/null; then
        gauntlet_pretooluse_decision "deny" \
            "gauntlet: this deletes test or fixture files, the shortest path to a green gate. If the test is genuinely obsolete, say which and let the user delete it — or set GAUNTLET=off."
    fi

    if printf '%s' "$CMD" | grep -qE \
        "${CMDPOS}git[^;&|]*(--no-verify|--no-validate)|${CMDPOS}SKIP=[a-z,-]+[[:space:]]+git" \
        2>/dev/null; then
        gauntlet_pretooluse_decision "deny" \
            "gauntlet: this bypasses the pre-commit/pre-push hooks. Fix what they are reporting instead."
    fi

    # Uninstalling the tooling is the same move as editing the config that invokes it, and it
    # routes around a Write/Edit guard entirely.
    if printf '%s' "$CMD" | grep -qE \
        "${CMDPOS}(uv[[:space:]]+remove|pip[[:space:]]+uninstall|poetry[[:space:]]+remove|npm[[:space:]]+(uninstall|rm)|pnpm[[:space:]]+remove|yarn[[:space:]]+remove)[^;&|]*(pytest|mypy|ruff|cov|lint|eslint|jest|vitest|stryker|mutmut|pre-commit)" \
        2>/dev/null; then
        gauntlet_pretooluse_decision "deny" \
            "gauntlet: this uninstalls a quality tool the gate runs. Removing the checker is not fixing the check."
    fi

    if printf '%s' "$CMD" | grep -qE \
        "${CMDPOS}(git[[:space:]]+(checkout|restore)[^;&|]*|sed[[:space:]]+-i[^;&|]*)(test|spec|pyproject|ruff|mypy|coveragerc|Justfile|justfile)" \
        2>/dev/null; then
        gauntlet_pretooluse_decision "ask" \
            "gauntlet: this reverts or rewrites tests or gate configuration in place."
    fi
    exit 0
fi

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -n "$FILE" ] || exit 0

# The target file's own repo, not the session's cwd: editing the plugin's tests from anywhere
# is still plugin development.
_fdir=$(dirname "$FILE")
_ftop=$(git -C "$_fdir" rev-parse --show-toplevel 2>/dev/null)
[ -n "$_ftop" ] && gauntlet_is_own_repo "$_ftop" && exit 0

# Documentation is exempt from every content rule: prose ABOUT a suppression marker is not a
# suppression. Documenting `type: ignore` in a README must not count as adding one.
CONTENT_RULES=1
case "$FILE" in
    *.md | *.mdx | *.rst | *.txt) CONTENT_RULES=0 ;;
esac

case "$TOOL" in
    Edit) OLD=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null)
          NEW=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null) ;;
    Write) NEW=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null)
           OLD=''
           [ -r "$FILE" ] && OLD=$(cat "$FILE" 2>/dev/null) ;;
    *) CONTENT_RULES=0; OLD=''; NEW='' ;;
esac

if [ "$CONTENT_RULES" -eq 1 ]; then
    # --- Suppression markers added to code ---------------------------------------------
    # Counted before and after: a file that ALREADY contains a suppression is not flagged for
    # an unrelated edit, only for adding one more.
    #
    # A marker only counts in a language where it DOES something. `type: ignore` in a shell
    # script suppresses nothing, so scanning .sh for it yields pure false positives — most
    # sharply on the test files of a guard like this one, which necessarily contain every
    # pattern the guard matches.
    MARKERS=''
    case "$FILE" in
        *.py | *.pyi | *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.vue | *.svelte \
            | *.toml | *.cfg | *.ini)
            MARKERS='#[[:space:]]*type:[[:space:]]*ignore
#[[:space:]]*pragma:[[:space:]]*no[[:space:]]*cover
@pytest\.mark\.(skip|skipif|xfail)
pytest\.skip\(
unittest\.skip
eslint-disable
@ts-(ignore|nocheck)
(describe|it|test)\.(skip|todo)\(
(^|[[:space:]])(xit|xdescribe)\('
            ;;
    esac

    for _m in $MARKERS; do
        _n_new=$(printf '%s\n' "$NEW" | grep -cE "$_m" 2>/dev/null)
        _n_old=$(printf '%s\n' "$OLD" | grep -cE "$_m" 2>/dev/null)
        case "$_n_new" in '' | *[!0-9]*) _n_new=0 ;; esac
        case "$_n_old" in '' | *[!0-9]*) _n_old=0 ;; esac
        if [ "$_n_new" -gt "$_n_old" ]; then
            gauntlet_pretooluse_decision "deny" \
                "gauntlet: this adds a check-suppressing marker matching \`$_m\` to \`$FILE\`. That silences the gate instead of satisfying it. Fix the underlying failure — or if the suppression is genuinely warranted, say so and let the user add it."
        fi
    done

    # --- A coverage threshold moving ---------------------------------------------------
    # Lowering the floor turns every uncovered line green at once, and it adds no marker: the
    # keyword is present on both sides, only the number moves. Not filtered by extension — a
    # CI shell script really can carry `--cov-fail-under`.
    THRESHOLDS='fail_under
cov-fail-under
minimum_coverage
coverageThreshold'

    for _t in $THRESHOLDS; do
        _o=$(printf '%s\n' "$OLD" | grep -oE -- "$_t[^0-9]*[0-9]+" 2>/dev/null | head -1)
        _n=$(printf '%s\n' "$NEW" | grep -oE -- "$_t[^0-9]*[0-9]+" 2>/dev/null | head -1)
        if [ -n "$_o" ] && [ -n "$_n" ] && [ "$_o" != "$_n" ]; then
            gauntlet_pretooluse_decision "deny" \
                "gauntlet: this moves a coverage threshold ($_o -> $_n) in \`$FILE\`. Lowering the floor turns every uncovered line green at once. Raise the coverage instead."
        fi
    done

    # --- Gutting an existing test file -------------------------------------------------
    # A Write that replaces a test file with something far smaller is a deletion in a hat.
    # ponytail: byte-size heuristic at 50%; an AST diff of removed test functions is the
    # upgrade path if this misses cases in practice.
    if [ "$TOOL" = "Write" ] && [ -n "$OLD" ] &&
        printf '%s' "$FILE" | grep -qE '(^|/)(tests?|spec)/|(test_|_test|\.test\.|\.spec\.)' 2>/dev/null; then
        _old_len=$(printf '%s' "$OLD" | wc -c | tr -d ' ')
        _new_len=$(printf '%s' "$NEW" | wc -c | tr -d ' ')
        if [ "$_old_len" -gt 200 ] && [ "$((_new_len * 2))" -lt "$_old_len" ]; then
            gauntlet_pretooluse_decision "deny" \
                "gauntlet: this rewrite shrinks the test file \`$FILE\` by more than half ($_old_len -> $_new_len bytes). Removing coverage is the shortest path to a green gate. If those tests are genuinely obsolete, say which and let the user remove them."
        fi
    fi
fi

# --- Protected paths: escalate, do not block -------------------------------------------
# Each entry is a file whose edit can turn a red gate green without fixing anything — but all
# of them have legitimate uses too, so this is the `ask` half.
PROTECTED_PATHS='(^|/)\.claude/gauntlet\.json$
(^|/)\.claude/settings(\.local)?\.json$
(^|/)pyproject\.toml$
(^|/)\.coveragerc
(^|/)setup\.cfg$
(^|/)tox\.ini$
(^|/)ruff\.toml$
(^|/)\.ruff\.toml$
(^|/)\.?mypy\.ini$
(^|/)[Jj]ustfile$
(^|/)Makefile$
(^|/)package\.json$
(^|/)\.github/workflows/
(^|/)\.pre-commit-config\.yaml$
(^|/)(jest|vitest|playwright|eslint)\.config\.[cm]?[jt]s$
(^|/)\.eslintrc
(^|/)tsconfig([.a-z]*)?\.json$
(^|/)gauntlet/(scripts|hooks)/'

for _p in $PROTECTED_PATHS; do
    if printf '%s' "$FILE" | grep -qE "$_p" 2>/dev/null; then
        gauntlet_pretooluse_decision "ask" \
            "gauntlet: \`$FILE\` configures the quality gate itself. Editing it can turn a red gate green without fixing anything. Confirm you want this change, or fix the underlying failure instead."
    fi
done

exit 0
