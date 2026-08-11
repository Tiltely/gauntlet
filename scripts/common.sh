#!/bin/sh
# Shared helpers for the gauntlet hooks. Sourced, never executed directly.
#
# Design rules every hook here obeys:
#   1. Every payload field is OPTIONAL. The documented Stop/PreToolUse schema was never
#      observed first-hand, so nothing load-bearing may depend on a field being present.
#      Missing field -> the most conservative fallback, never a crash.
#   2. Any internal failure exits 0. The gauntlet blocks on YOUR code, never on its own
#      bugs. A broken hook that cannot be escaped is worse than no hook.
#   3. POSIX sh only, no bashisms. jq is the single external dependency.

# Read stdin once. Echoes the payload; empty on failure.
gauntlet_read_input() {
    cat 2>/dev/null || printf ''
}

# GAUNTLET_DEBUG=1 records the real payload so the schema can be verified against
# observation rather than documentation. This is step 1 of the README's install check.
gauntlet_debug_dump() {
    [ "${GAUNTLET_DEBUG:-}" = "1" ] || return 0
    _dir="${TMPDIR:-/tmp}/gauntlet-payloads"
    mkdir -p "$_dir" 2>/dev/null || return 0
    printf '%s\n' "$1" >>"$_dir/${2:-unknown}.jsonl" 2>/dev/null
    return 0
}

# Hard off switch. An ENVIRONMENT variable on purpose: a file inside the repo could be
# created by the very agent the gauntlet constrains, which would make the cage
# self-opening. The hook process does not inherit exports from the agent's Bash calls.
gauntlet_is_off() {
    [ "${GAUNTLET:-}" = "off" ]
}

# The plugin's own repo is exempt from the content guards.
#
# Not a convenience: a guard's tests and docs necessarily contain every pattern the guard
# matches on, so with the guard live its own development is impossible — writing the test for
# "blocks `--no-verify`" is itself blocked. Learned by hitting it four times in a row while
# building this file.
#
# Detection is the plugin's own manifest, so a fork gets the same exemption, and no other repo
# can claim it by naming a directory.
gauntlet_is_own_repo() {
    _m="$1/.claude-plugin/plugin.json"
    [ -r "$_m" ] || return 1
    [ "$(jq -r '.name // empty' "$_m" 2>/dev/null)" = "gauntlet" ]
}

# jq is required. Absent -> the plugin disables itself with one visible warning per
# session rather than silently doing nothing (silence would read as "the gate passed").
gauntlet_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    _flag="${TMPDIR:-/tmp}/gauntlet-nojq-warned"
    if [ ! -f "$_flag" ]; then
        : >"$_flag" 2>/dev/null
        printf '{"systemMessage":"gauntlet is inactive: jq is not installed (brew install jq)"}\n'
    fi
    return 1
}

# Resolve the repo root from the payload's cwd, falling back to the hook process's own
# pwd when the field is absent. Symlinks are resolved (`pwd -P`) so the root and a payload
# file path can be compared: on macOS /var is a symlink to /private/var, so an unresolved
# root would fail to prefix-match an unresolved file path and every pattern check would
# silently pass.
gauntlet_root() {
    _cwd=$(printf '%s' "$1" | jq -r '.cwd // empty' 2>/dev/null)
    [ -n "$_cwd" ] && [ -d "$_cwd" ] || _cwd=$(pwd)
    _top=$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$_top" ] || _top="$_cwd"
    (cd "$_top" 2>/dev/null && pwd -P) || printf '%s' "$_top"
}

# Path of <file> relative to <root>, with both sides symlink-resolved. Falls back to the
# input unchanged when the file's directory does not exist yet.
gauntlet_relpath() {
    _root="$1"
    _file="$2"
    _dir=$(cd "$(dirname "$_file")" 2>/dev/null && pwd -P)
    if [ -n "$_dir" ]; then
        _file="$_dir/$(basename "$_file")"
    fi
    printf '%s' "$_file" | sed "s|^${_root}/||"
}

# Translate a glob to an ERE anchored at both ends.
#
# Supported subset: `**` (any depth), `*` (within one path segment), `?` (one char).
# Brace expansion is deliberately NOT supported — writing `{json,csv}` correctly in sed
# costs more than writing the two patterns out, so the manifest spells them out and
# core/manifest.md says so.
gauntlet_glob_to_ere() {
    printf '%s' "$1" | sed \
        -e 's/[.^$+()|{}]/\\&/g' \
        -e 's/\[/\\[/g' -e 's/\]/\\]/g' \
        -e 's|\*\*/|@@GS@@|g' \
        -e 's|\*\*|@@GS@@|g' \
        -e 's|\*|[^/]*|g' \
        -e 's|?|[^/]|g' \
        -e 's|@@GS@@|.*|g' \
        -e 's|^|^|' -e 's|$|$|'
}

# Build one alternated ERE from a JSON array of globs in a manifest.
# Empty/absent array -> empty output, and each caller decides what that means.
gauntlet_patterns_to_ere() {
    _ere=''
    for _pat in $(jq -r "$2[]? // empty" "$1" 2>/dev/null); do
        _one=$(gauntlet_glob_to_ere "$_pat")
        if [ -z "$_ere" ]; then _ere="$_one"; else _ere="$_ere|$_one"; fi
    done
    printf '%s' "$_ere"
}

# Files changed in the working tree, tracked and untracked, relative to the repo root.
#
# git is the source of truth on purpose: it makes the gate indifferent to WHO wrote the
# change — main turn, subagent, or workflow — which is why no SubagentStop hook is needed.
gauntlet_changed_files() {
    {
        git -C "$1" diff --name-only HEAD 2>/dev/null
        git -C "$1" ls-files --others --exclude-standard 2>/dev/null
    } | sed '/^$/d' | sort -u
}

# Emit a PreToolUse decision ("ask" | "deny" | "allow") and exit 0.
gauntlet_pretooluse_decision() {
    jq -n --arg d "$1" --arg r "$2" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: $d,
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

# --- The ledger --------------------------------------------------------------------------
#
# The gauntlet is not "ask me about everything important". It is "make sure everything
# important was done the way we agreed". Those are different machines: a mid-turn permission
# prompt hands the judgement to a human who has not seen the turn yet and has no way to check
# the claim, and — worse — it trains that human to click through. A receipt at the end hands
# them the finished turn and every gate-shaped thing that happened inside it.
#
# So the guards that cannot honestly be described as "this only makes sense in order to
# cheat" no longer stop anything. They write a line here, and gate.sh reads it back when the
# turn closes.
#
# Session-scoped and in TMPDIR on purpose: a file inside the repo would be one more artefact
# the agent can rewrite, and the ledger needs to outlive nothing but the turn.

# Session id from any hook payload, sanitised for use in a filename. Absent -> a shared
# fallback bucket, which is imprecise but never a crash (design rule 1).
gauntlet_session() {
    _s=$(printf '%s' "$1" | jq -r '.session_id // empty' 2>/dev/null)
    [ -n "$_s" ] || _s=nosession
    printf '%s' "$_s" | tr -c 'a-zA-Z0-9._-' '_'
}

# Stable short digest of stdin. Three implementations because the fallback matters more than
# the algorithm: an unavailable hasher must degrade to a weaker key, never to no key at all.
gauntlet_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum 2>/dev/null | awk '{print $1}'
    else
        cksum 2>/dev/null | tr -cd '0-9'
    fi
}

gauntlet_ledger_file() {
    printf '%s/gauntlet-ledger-%s' "${TMPDIR:-/tmp}" "$1"
}

gauntlet_ledger_append() {
    printf -- '- %s\n' "$2" >>"$(gauntlet_ledger_file "$1")" 2>/dev/null
    return 0
}

# Print the ledger and clear it. The receipt covers THIS turn, not the session so far:
# repeating yesterday's entries every turn is how a receipt becomes wallpaper.
gauntlet_ledger_take() {
    _f=$(gauntlet_ledger_file "$1")
    [ -r "$_f" ] || return 0
    cat "$_f" 2>/dev/null
    rm -f "$_f" 2>/dev/null
    return 0
}

# --- Challenge, then trust -----------------------------------------------------------------
#
# For the shapes that are usually a shortcut and occasionally legitimate. The FIRST attempt is
# denied with the objection attached; an IDENTICAL re-attempt in the same session goes through
# and lands on the receipt.
#
# Yes, this is a lock the agent can open. The trade is deliberate: a deny with no way out does
# not remove the decision, it routes it to the user mid-turn — the exact behaviour this plugin
# is being fixed to stop. What the mechanism actually buys is that no gate-shaped action can
# happen REFLEXIVELY. The agent has to read the objection, answer it, and act again on purpose;
# and because the objection arrives as a tool result, it argues with the agent instead of
# interrupting the human. The ledger is what keeps that honest.
#
# The hard `deny` rules are NOT routed through here. "Only makes sense in order to cheat" has
# no second reading, so it gets no second attempt.
#
# ponytail: exact-fingerprint match, so a re-worded retry is challenged again. Normalising
# whitespace is the upgrade path if that turns out to be common in practice.
gauntlet_challenge() {
    _sess="$1"
    _rule="$2"
    _subject="$3"
    _reason="$4"
    _fp=$(printf '%s\n%s' "$_rule" "$_subject" | gauntlet_hash)
    _mark="${TMPDIR:-/tmp}/gauntlet-challenge-${_sess}-${_fp}"

    # Affirmed once, trusted for the rest of the session for this exact action — but recorded
    # every time. Re-arguing an answered objection is nagging, not a guard.
    if [ -f "$_mark" ]; then
        gauntlet_ledger_append "$_sess" "$_rule (challenged, re-affirmed): $_subject"
        exit 0
    fi

    : >"$_mark" 2>/dev/null
    gauntlet_pretooluse_decision "deny" "$_reason"
}

# Close a Stop hook: emit the turn's receipt merged with whatever the caller wanted to say,
# then exit 0. Silent when there is nothing to report — a hook that prints every turn is a
# hook nobody reads.
#
# Every one of gate.sh's exit paths funnels through here, including the ones where the gate
# never ran. A receipt that only appears when the tests happened to run is not a receipt.
gauntlet_stop_exit() {
    _sess="$1"
    _extra="$2"
    _led=$(gauntlet_ledger_take "$_sess")
    _msg=''
    [ -n "$_led" ] && _msg="gauntlet let these through this turn — worth a look before the PR:
$_led"

    if [ -n "$_extra" ] && [ -n "$_msg" ]; then
        printf '%s' "$_extra" | jq --arg m "$_msg" \
            '.systemMessage = ((.systemMessage // "") +
                               (if (.systemMessage // "") == "" then "" else "\n\n" end) + $m)'
    elif [ -n "$_extra" ]; then
        printf '%s' "$_extra"
    elif [ -n "$_msg" ]; then
        jq -n --arg m "$_msg" '{systemMessage: $m}'
    fi
    exit 0
}
