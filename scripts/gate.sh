#!/bin/sh
# gauntlet — Stop hook: the turn does not close while the repo's fast check is red.
#
# One rule, no heuristics: if the turn touched source, RUN the tests. The plugin does not
# try to detect whether the agent lied about running them — a claim detector is evaded by
# changing words, and matching on phrases like "it works now" fights the user's own output
# style. An executed command cannot be talked around.
#
# Exit 0            -> the turn closes.
# {"decision":"block"} -> the agent keeps working and reads `reason`.

. "$(dirname "$0")/common.sh"

gauntlet_is_off && exit 0

INPUT=$(gauntlet_read_input)
[ -n "$INPUT" ] || exit 0
gauntlet_debug_dump "$INPUT" "Stop"
gauntlet_require_jq || exit 0

ROOT=$(gauntlet_root "$INPUT")
MANIFEST="$ROOT/.claude/gauntlet.json"

# No manifest, no gate. This is the opt-in rollout: a repo nobody configured can never be
# blocked by a command guessed on its behalf.
[ -r "$MANIFEST" ] || exit 0

# Did this turn edit anything?
#
# An ABSENT tool_calls field must not read as "no edits" — that would silently disable the
# gate on any harness version whose payload omits it. So the presence of the field is
# checked separately from its contents, and "unknown" falls through to the git check below,
# which is the real evidence anyway.
if [ "$(printf '%s' "$INPUT" | jq -r 'has("tool_calls")' 2>/dev/null)" = "true" ]; then
    EDITS=$(printf '%s' "$INPUT" |
        jq -r '[.tool_calls[]?.tool_name // empty]
               | map(select(. == "Edit" or . == "Write" or . == "NotebookEdit"))
               | length' 2>/dev/null)
    case "$EDITS" in
        '' | *[!0-9]*) EDITS=1 ;;
    esac
else
    EDITS=1
fi
[ "$EDITS" -gt 0 ] || exit 0

CHANGED=$(gauntlet_changed_files "$ROOT")
[ -n "$CHANGED" ] || exit 0

# Filter to the paths the manifest calls source. An empty sourcePatterns means "any
# change counts" rather than "nothing counts": a manifest that exists is an opt-in, so the
# safe reading of a missing filter is to gate more, not less.
SRC_ERE=$(gauntlet_patterns_to_ere "$MANIFEST" '.sourcePatterns')
if [ -n "$SRC_ERE" ]; then
    FILES=$(printf '%s\n' "$CHANGED" | grep -E "$SRC_ERE" 2>/dev/null)
else
    FILES="$CHANGED"
fi
[ -n "$FILES" ] || exit 0

CMD=$(jq -r '.fast // empty' "$MANIFEST" 2>/dev/null)
[ -n "$CMD" ] || exit 0

# {files} lets a manifest scope the command to what changed; a command without it runs as
# written, so a `just` recipe can resolve its own scope.
case "$CMD" in
    *'{files}'*)
        FILES_ONELINE=$(printf '%s\n' "$FILES" | tr '\n' ' ')
        CMD=$(printf '%s' "$CMD" | sed "s|{files}|${FILES_ONELINE}|g")
        ;;
esac

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null)
[ -n "$SESSION" ] || SESSION=nosession
COUNTER="${TMPDIR:-/tmp}/gauntlet-retry-$(printf '%s' "$SESSION" | tr -c 'a-zA-Z0-9._-' '_')"

# Give up after three consecutive blocks. An agent that cannot fix something in three
# tries will not fix it in the fourth, and the user needs to see the turn to intervene.
# Without this the gate becomes an inescapable loop, which is worse than no gate.
TRIES=0
[ -r "$COUNTER" ] && TRIES=$(cat "$COUNTER" 2>/dev/null)
case "$TRIES" in '' | *[!0-9]*) TRIES=0 ;; esac
if [ "$TRIES" -ge 3 ]; then
    rm -f "$COUNTER" 2>/dev/null
    jq -n --arg c "$CMD" '{
        systemMessage: ("gauntlet gave up after 3 blocked attempts — `" + $c +
                        "` is still failing. The turn is yours.")
    }'
    exit 0
fi

OUT=$( (cd "$ROOT" 2>/dev/null && eval "$CMD") 2>&1 )
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
    rm -f "$COUNTER" 2>/dev/null
    exit 0
fi

printf '%s' "$((TRIES + 1))" >"$COUNTER" 2>/dev/null

TAIL=$(printf '%s\n' "$OUT" | tail -40)
jq -n --arg c "$CMD" --arg o "$TAIL" --arg n "$((TRIES + 1))" '{
    decision: "block",
    reason: ("gauntlet: `" + $c + "` is failing (attempt " + $n + " of 3). " +
             "Fix the cause, do not weaken the check.\n\nLast 40 lines:\n" + $o)
}'
exit 0
