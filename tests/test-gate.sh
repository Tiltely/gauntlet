#!/bin/sh
# Tests for the Stop hook. The safeguards (off switch, retry cap, never-fail-on-own-bug)
# get a case each: an inescapable gate is worse than no gate, so those cases are the ones
# that must never rot.

. "$(dirname "$0")/helpers.sh"

printf 'gate.sh\n'

# --- no manifest: an unconfigured repo can never be blocked ----------------------------
R=$(make_repo)
printf 'x = 2\n' >"$R/src/pkg/mod.py"
OUT=$(stop_payload "$R" "$(new_session a)" Edit | sh "$SCRIPTS/gate.sh")
check "no manifest -> silent" EMPTY "$OUT"

# --- failing fast command blocks the turn ----------------------------------------------
write_manifest "$R" "sh -c 'echo boom-line-here; exit 1'"
OUT=$(stop_payload "$R" "$(new_session b)" Edit | sh "$SCRIPTS/gate.sh")
check "failing fast -> block" '"decision": "block"' "$OUT"
check "failing fast -> shows output" 'boom-line-here' "$OUT"
check "failing fast -> names attempt" 'attempt 1 of 3' "$OUT"

# --- passing fast command closes the turn ----------------------------------------------
write_manifest "$R" "true"
OUT=$(stop_payload "$R" "$(new_session c)" Write | sh "$SCRIPTS/gate.sh")
check "passing fast -> silent" EMPTY "$OUT"

# --- off switch ------------------------------------------------------------------------
write_manifest "$R" "false"
OUT=$(stop_payload "$R" "$(new_session d)" Edit | GAUNTLET=off sh "$SCRIPTS/gate.sh")
check "GAUNTLET=off -> silent" EMPTY "$OUT"

# --- a turn that edited nothing --------------------------------------------------------
OUT=$(stop_payload "$R" "$(new_session e)" Read Grep | sh "$SCRIPTS/gate.sh")
check "no edit in turn -> silent" EMPTY "$OUT"

# --- an absent tool_calls field must not disable the gate ------------------------------
OUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s"}' "$(new_session f)" "$R" |
    sh "$SCRIPTS/gate.sh")
check "unknown tool_calls -> still gates" '"decision": "block"' "$OUT"

# --- changes outside sourcePatterns ----------------------------------------------------
R2=$(make_repo)
write_manifest "$R2" "false"
printf '# docs\n' >"$R2/README.md"
OUT=$(stop_payload "$R2" "$(new_session g)" Write | sh "$SCRIPTS/gate.sh")
check "change outside sourcePatterns -> silent" EMPTY "$OUT"

# --- retry cap: three blocks, then the turn is the user's -----------------------------
S=$(new_session h)
write_manifest "$R" "false"
for _i in 1 2 3; do
    OUT=$(stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh")
done
check "third block still blocks" '"decision": "block"' "$OUT"
OUT=$(stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh")
check "fourth attempt -> gives up" 'gave up after 3' "$OUT"
OUT=$(stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh")
check "counter reset after giving up" '"decision": "block"' "$OUT"

# --- a passing run clears the counter --------------------------------------------------
S=$(new_session i)
write_manifest "$R" "false"
stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh" >/dev/null
write_manifest "$R" "true"
stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh" >/dev/null
write_manifest "$R" "sh -c 'exit 1'"
OUT=$(stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh")
check "pass resets attempt counter" 'attempt 1 of 3' "$OUT"

# --- the plugin never blocks on its own bugs ------------------------------------------
printf 'not json at all {{{\n' >"$R/.claude/gauntlet.json"
OUT=$(stop_payload "$R" "$(new_session j)" Edit | sh "$SCRIPTS/gate.sh")
check "corrupt manifest -> silent" EMPTY "$OUT"

write_manifest "$R" "definitely-not-a-real-command-xyz"
OUT=$(stop_payload "$R" "$(new_session k)" Edit | sh "$SCRIPTS/gate.sh")
check "missing command -> blocks with the shell error" '"decision": "block"' "$OUT"

OUT=$(printf 'garbage not json' | sh "$SCRIPTS/gate.sh")
check "garbage payload -> silent" EMPTY "$OUT"

OUT=$(printf '' | sh "$SCRIPTS/gate.sh")
check "empty payload -> silent" EMPTY "$OUT"

# --- {files} substitution --------------------------------------------------------------
write_manifest "$R" "sh -c 'echo GOT:{files}; exit 1'"
OUT=$(stop_payload "$R" "$(new_session l)" Edit | sh "$SCRIPTS/gate.sh")
check "{files} is substituted" 'GOT:src/pkg/mod.py' "$OUT"

# --- the receipt -------------------------------------------------------------------------
# What protect.sh let through has to surface somewhere, or dropping the permission prompt was
# just a way of hiding it. The Stop hook is that somewhere.
S=$(new_session m)
LED=$(ledger_of "$S")
rm -f "$LED"
printf -- '- gate config edited: pyproject.toml\n' >"$LED"

write_manifest "$R" "true"
OUT=$(stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh")
check "a passing gate still delivers the receipt" 'gate config edited: pyproject.toml' "$OUT"
check "the receipt is cleared once delivered" EMPTY "$(cat "$LED" 2>/dev/null)"

# A repo with no manifest is not gated at all, but protect.sh still guarded it, so the receipt
# must survive the early exit.
printf -- '- in-place revert/rewrite (challenged, re-affirmed): git checkout -- t\n' >"$LED"
rm -f "$R2/.claude/gauntlet.json"
OUT=$(stop_payload "$R2" "$S" Edit | sh "$SCRIPTS/gate.sh")
check "no manifest -> receipt still delivered" 're-affirmed' "$OUT"

# A block is not the turn closing. Spending the ledger there would lose it before the user
# ever sees a finished turn.
printf -- '- gate config edited: pyproject.toml\n' >"$LED"
write_manifest "$R" "false"
OUT=$(stop_payload "$R" "$S" Edit | sh "$SCRIPTS/gate.sh")
check "a block does not spend the receipt" '"decision": "block"' "$OUT"
check "the ledger survives a block" 'gate config edited' "$(cat "$LED" 2>/dev/null)"
rm -f "$LED"

rm -rf "$R" "$R2"
summary gate.sh
