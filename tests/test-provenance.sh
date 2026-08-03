#!/bin/sh
# Tests for the fixture-provenance hook.
#
# The prose case is the load-bearing one: if "the user gave it to me" satisfies
# captured_by, the whole mechanism collapses into a form to fill in, and it ships
# again with a provenance file attached.

. "$(dirname "$0")/helpers.sh"

printf 'provenance.sh\n'

R=$(make_repo)
write_manifest "$R" "true"
FIX="$R/tests/unit/fixtures/benefits.csv"

write() { # write <file> <content>
    pretooluse_payload Write "$(jq -n --arg f "$1" --arg c "$2" '{file_path:$f, content:$c}')" "$R" |
        sh "$SCRIPTS/provenance.sh"
}

meta() { # meta <captured_by> [omit-field]
    jq -n --arg by "$1" --arg omit "${2:-}" '{
        captured_from: "GET https://api.example.com/v2/benefits?account=4471",
        captured_at: "2026-07-27",
        captured_by: $by,
        sample_of: "real staging account"
    } | if $omit != "" then del(.[$omit]) else . end'
}

# --- a fixture with no provenance ------------------------------------------------------
OUT=$(write "$FIX" 'col_a,col_b
1,2')
check "fixture without meta -> deny" '"permissionDecision": "deny"' "$OUT"
check "deny names the sidecar" 'benefits.csv.meta.json' "$OUT"
check "deny cites the real failure" 'the CSV incident' "$OUT"

# --- with the sidecar in place ---------------------------------------------------------
meta "just capture-provider-benefits 4471" >"$FIX.meta.json"
check "fixture with meta -> silent" EMPTY "$(write "$FIX" 'col_a,col_b
1,2')"
rm -f "$FIX.meta.json"

# --- writing the sidecar itself -------------------------------------------------------
check "complete meta -> silent" EMPTY "$(write "$FIX.meta.json" "$(meta 'just capture-provider-benefits 4471')")"
check "curl meta -> silent" EMPTY "$(write "$FIX.meta.json" "$(meta 'curl -s https://api.example.com/v2/benefits')")"
check "repo script meta -> silent" EMPTY "$(write "$FIX.meta.json" "$(meta 'uv run python scripts/capture.py 4471')")"
check "psql meta -> silent" EMPTY "$(write "$FIX.meta.json" "$(meta 'psql -c "select * from benefits limit 5"')")"

OUT=$(write "$FIX.meta.json" "$(meta 'just capture' captured_from)")
check "missing captured_from -> deny" '"permissionDecision": "deny"' "$OUT"
check "deny names the missing field" 'captured_from' "$OUT"
check "missing sample_of -> deny" '"permissionDecision": "deny"' \
    "$(write "$FIX.meta.json" "$(meta 'just capture' sample_of)")"

# --- prose instead of a command -------------------------------------------------------
check "prose captured_by -> deny" '"permissionDecision": "deny"' \
    "$(write "$FIX.meta.json" "$(meta 'the user gave me this file')")"
check "n/a captured_by -> deny" '"permissionDecision": "deny"' \
    "$(write "$FIX.meta.json" "$(meta 'n/a')")"
check "empty captured_by -> deny" '"permissionDecision": "deny"' \
    "$(write "$FIX.meta.json" "$(meta '')")"
check "invented command -> deny" '"permissionDecision": "deny"' \
    "$(write "$FIX.meta.json" "$(meta 'fetchTheBenefits from the API')")"

# An Edit carries only a fragment of the file; validating a fragment would reject
# legitimate corrections to an already-validated sidecar.
check "Edit of a sidecar -> silent" EMPTY \
    "$(pretooluse_payload Edit '{"file_path":"'"$FIX"'.meta.json","old_string":"a","new_string":"b"}' "$R" |
        sh "$SCRIPTS/provenance.sh")"

# --- out of scope ---------------------------------------------------------------------
check "source file -> silent" EMPTY "$(write "$R/src/pkg/mod.py" 'x = 3')"
check "test file -> silent" EMPTY "$(write "$R/tests/unit/test_mod.py" 'def test_z(): pass')"

# --- safeguards -----------------------------------------------------------------------
check "GAUNTLET=off -> silent" EMPTY \
    "$(pretooluse_payload Write "$(jq -n --arg f "$FIX" '{file_path:$f, content:"a"}')" "$R" |
        GAUNTLET=off sh "$SCRIPTS/provenance.sh")"
rm -f "$R/.claude/gauntlet.json"
check "no manifest -> silent" EMPTY "$(write "$FIX" 'a,b')"
check "garbage payload -> silent" EMPTY "$(printf 'nonsense' | sh "$SCRIPTS/provenance.sh")"
check "empty payload -> silent" EMPTY "$(printf '' | sh "$SCRIPTS/provenance.sh")"

rm -rf "$R"
summary provenance.sh
