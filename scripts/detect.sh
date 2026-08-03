#!/bin/sh
# gauntlet — stack detection. Prints a SUGGESTED manifest as JSON on stdout.
#
# Used by /gauntlet:setup, never by a hook: a guessed command must never gate a turn
# silently. The skill measures the suggestion before writing it.
#
# Usage: sh detect.sh [repo-root]

ROOT="${1:-$(pwd)}"
cd "$ROOT" 2>/dev/null || exit 1

has() { [ -e "$ROOT/$1" ]; }
just_has() { [ -r "$ROOT/Justfile" ] && grep -qE "^$1:" "$ROOT/Justfile" 2>/dev/null; }
npm_has() { [ -r "$ROOT/package.json" ] && jq -e ".scripts.\"$1\"" "$ROOT/package.json" >/dev/null 2>&1; }

STACK=unknown
FAST=''
FULL=''
MUTATION=''
SOURCES='"src/**"'
FIXTURES='"tests/**/fixtures/**"'

# Bazel is deliberately left unresolved: guessing a target produces blocks nobody can
# explain, which is how a quality gate loses the user's trust for good.
if has MODULE.bazel || has WORKSPACE; then
    STACK=bazel
elif has pyproject.toml; then
    STACK=python
    if has uv.lock; then RUN="uv run"; else RUN=""; fi
    just_has check && FAST="just check"
    [ -n "$FAST" ] || FAST="$RUN ruff check {files} && $RUN mypy {files}"
    if just_has test-cov; then FULL="just check && just test-cov"
    elif just_has test; then FULL="just check && just test"
    else FULL="$RUN ruff check . && $RUN mypy src tests && $RUN pytest"
    fi
    MUTATION="$RUN mutmut run --paths-to-mutate {files}"
    SOURCES='"src/**/*.py"'
    FIXTURES='"tests/**/fixtures/**", "**/*.sample.json", "**/*.sample.csv"'
elif has package.json; then
    STACK=node
    npm_has check && FAST="npm run check"
    [ -n "$FAST" ] || { npm_has typecheck && npm_has lint && FAST="npm run lint && npm run typecheck"; }
    [ -n "$FAST" ] || { npm_has lint && FAST="npm run lint"; }
    if npm_has check && npm_has test; then FULL="npm run check && npm test"
    elif npm_has test; then FULL="npm test"
    fi
    MUTATION="npx stryker run --mutate {files}"
    SOURCES='"src/**/*.ts", "src/**/*.tsx", "apps/**/*.ts", "apps/**/*.tsx", "packages/**/*.ts", "packages/**/*.tsx"'
    FIXTURES='"**/__fixtures__/**", "**/*.fixture.json", "**/*.sample.json"'
fi

# Brace expansion is not supported by the glob matcher — patterns are spelled out above.
jq -n \
    --arg stack "$STACK" --arg fast "$FAST" --arg full "$FULL" --arg mutation "$MUTATION" \
    --argjson sources "[$SOURCES]" --argjson fixtures "[$FIXTURES]" \
    '{
        _stack: $stack,
        fast: $fast,
        full: $full,
        mutation: $mutation,
        sourcePatterns: $sources,
        fixturePatterns: $fixtures
    } | with_entries(select(.value != "" and .value != null))'
