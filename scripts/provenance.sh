#!/bin/sh
# gauntlet — PreToolUse hook: no fixture of an external payload without provenance.
#
# The failure this exists for, from a real production incident: the agent assumed an upstream
# CSV schema, wrote the parser against that assumption AND the fixture against the same
# assumption. Every test passed. It shipped against columns that never existed. 100% branch
# coverage did not see it, and neither would mutation testing — both check the test against
# the code, never the code against reality.
#
# What this hook can and cannot do: it CANNOT prove a fixture is real. It makes lying
# expensive — the agent has to invent a reproducible command that gets committed, is
# reviewable, and can be re-run later. The point is not impossibility, it is inverting the
# effort gradient: /gauntlet:capture is the cheap path, fabrication is the expensive one.

. "$(dirname "$0")/common.sh"

gauntlet_is_off && exit 0

INPUT=$(gauntlet_read_input)
[ -n "$INPUT" ] || exit 0
gauntlet_require_jq || exit 0

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

ROOT=$(gauntlet_root "$INPUT")
MANIFEST="$ROOT/.claude/gauntlet.json"
[ -r "$MANIFEST" ] || exit 0

REQUIRED='captured_from captured_at captured_by sample_of'

# --- Writing a .meta.json: validate it, so an empty shell does not unlock a fixture -----
case "$FILE" in
    *.meta.json)
        # An Edit touches an already-validated file and only carries a fragment of it;
        # validating a fragment would reject legitimate corrections.
        [ "$TOOL" = "Write" ] || exit 0
        CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null)
        MISSING=''
        for _f in $REQUIRED; do
            _v=$(printf '%s' "$CONTENT" | jq -r ".$_f // empty" 2>/dev/null)
            [ -n "$_v" ] || MISSING="$MISSING $_f"
        done
        if [ -n "$MISSING" ]; then
            gauntlet_pretooluse_decision "deny" \
                "gauntlet: this provenance file is missing:$MISSING. All four fields are required — captured_from, captured_at, captured_by, sample_of."
        fi
        # `captured_by` must be a RUNNABLE command, not prose. This is the field that makes
        # the claim checkable later, so it carries the whole mechanism: if "the user gave me
        # this file" satisfies it, provenance degrades into a form to fill in and the CSV incident
        # ships again with a sidecar attached.
        #
        # The test: the first token resolves as a command here, or is a well-known capture
        # tool that may simply not be installed on this machine. A shape check is not enough
        # — "the user gave me this file" and "n/a" both look like `word arg arg`.
        _by=$(printf '%s' "$CONTENT" | jq -r '.captured_by // empty' 2>/dev/null)
        _cmd0=$(printf '%s' "$_by" | awk '{print $1}')
        _known='curl wget http httpie psql mysql mysqlsh sqlite3 aws gh gcloud az docker
kubectl just make task npm npx pnpm yarn uv uvx poetry python python3 node deno bun
sh bash zsh jq scp rsync ssh temporal'
        _ok=0
        [ -n "$_cmd0" ] && command -v "$_cmd0" >/dev/null 2>&1 && _ok=1
        if [ "$_ok" -eq 0 ] && [ -n "$_cmd0" ]; then
            for _k in $_known; do
                [ "$_cmd0" = "$_k" ] && { _ok=1; break; }
            done
        fi
        if [ "$_ok" -eq 0 ]; then
            gauntlet_pretooluse_decision "deny" \
                "gauntlet: captured_by must BE a runnable command — \`$_cmd0\` does not resolve to one. Examples: \`just capture-provider-benefits 4471\`, \`curl -s https://api.../benefits\`, \`psql -c 'select ...'\`, \`uv run python scripts/capture.py 4471\`. A description is not reproducible, and reproducibility is the entire point of this field."
        fi
        exit 0
        ;;
esac

# --- Writing a fixture: it needs its provenance sidecar --------------------------------
FIX_ERE=$(gauntlet_patterns_to_ere "$MANIFEST" '.fixturePatterns')
[ -n "$FIX_ERE" ] || exit 0

REL=$(gauntlet_relpath "$ROOT" "$FILE")
printf '%s' "$REL" | grep -qE "$FIX_ERE" 2>/dev/null || exit 0

[ -r "${FILE}.meta.json" ] && exit 0

gauntlet_pretooluse_decision "deny" \
    "gauntlet: \`$REL\` is an external-payload fixture and has no provenance. Write \`${REL}.meta.json\` first, or run /gauntlet:capture to fetch the real thing:

{
  \"captured_from\": \"GET https://api.example.com/v2/benefits?account=4471\",
  \"captured_at\": \"$(date +%Y-%m-%d)\",
  \"captured_by\": \"just capture-provider-benefits 4471\",
  \"sample_of\": \"real staging account\"
}

A parser written against an assumed schema is how code ships against columns that never existed. Go get the real payload."
