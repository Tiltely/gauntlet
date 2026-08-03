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
