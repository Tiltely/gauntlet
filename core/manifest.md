# The manifest — `.claude/gauntlet.json`

One file per repo, at the repo root under `.claude/`. Its presence is what arms the
per-turn gate; its absence is what keeps unconfigured repos safe.

**Commit it.** It is project configuration, not user preference. Git-ignored, it would leave
every new worktree ungated and silent about it.

## Fields

| Field | Type | Used by | Meaning |
|---|---|---|---|
| `fast` | string | `Stop` hook | The per-turn gate. Paid at the end of every turn that touched source — keep it under 20 s warm |
| `full` | string | `/gauntlet:run` | The complete check, pre-PR. Minutes are fine |
| `mutation` | string | `/gauntlet:run` | Mutation-testing command. Always scoped to the diff |
| `sourcePatterns` | string[] | `Stop` hook | Which changed paths make the gate fire |
| `fixturePatterns` | string[] | `provenance.sh` | Which paths require a `.meta.json` sidecar |

Every field is optional, and each absence has a deliberate reading:

- No `fast` → no per-turn gate (but `provenance.sh` still applies).
- No `sourcePatterns` → **any** change arms the gate. A manifest that exists is an opt-in, so
  the safe reading of a missing filter is to gate more, not less.
- No `fixturePatterns` → no provenance requirement.

## `{files}` substitution

In `fast`, `full` and `mutation`, `{files}` is replaced by the changed paths, space
separated (for `fast`, filtered by `sourcePatterns`). A command without `{files}` runs as
written, so a `just` recipe can resolve its own scope.

Useful for linters (`ruff check {files}`, `eslint {files}`). Usually a mistake for
whole-program type checkers: `mypy --strict src/x/y.py` may be *slower* than `mypy src tests`
warm and report different errors, because it re-resolves the module graph. Measure before
believing.

## Glob subset

Patterns are matched against paths relative to the repo root.

| Pattern | Means |
|---|---|
| `**` | any depth, including none |
| `*` | anything within one path segment |
| `?` | one character |

**Brace expansion is not supported.** Write `["**/*.sample.json", "**/*.sample.csv"]`, not
`["**/*.sample.{json,csv}"]` — spelling both out costs less than making sed expand braces
correctly.

## Example — Python, uv, just

```json
{
  "fast": "just check",
  "full": "just check && just test-cov",
  "mutation": "uv run mutmut run --paths-to-mutate {files}",
  "sourcePatterns": ["src/**/*.py"],
  "fixturePatterns": ["tests/**/fixtures/**", "**/*.sample.json", "**/*.sample.csv"]
}
```

## Example — TypeScript monorepo

```json
{
  "fast": "npm run lint -- {files}",
  "full": "npm run check && npm test",
  "mutation": "npx stryker run --mutate {files}",
  "sourcePatterns": ["apps/**/*.ts", "apps/**/*.tsx", "packages/**/*.ts", "packages/**/*.tsx"],
  "fixturePatterns": ["**/__fixtures__/**", "**/*.fixture.json"]
}
```

## What is NOT configurable, on purpose

The list of protected artefacts in `scripts/protect.sh` — the coverage config, the linter
config, the workflows, the test files, this manifest itself. A configurable guard is a
removable guard: an agent blocked by the gate would simply edit the list of things it is not
allowed to edit.

Same reasoning puts the off switch in the environment (`GAUNTLET=off`) rather than in a file:
a file inside the repo is something the agent can create for itself.
