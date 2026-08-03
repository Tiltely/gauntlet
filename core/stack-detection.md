# Stack Detection

How `/gauntlet:setup` classifies a repo before suggesting commands. Extends
`lens/core/stack-detection.md`, which covers the Node side; the Python and build-system
rows below are what this plugin adds.

Detection only ever produces a *suggestion*. A hook never runs a guessed command — that is
why the gate is opt-in per repo.

## Signals → suggestion

| Classification | Signals | `fast` | `full` |
|---|---|---|---|
| `python-uv-just` | `pyproject.toml` + `uv.lock` + `Justfile` with a `check:` recipe | `just check` | `just check && just test-cov` (or `test`) |
| `python-uv` | `pyproject.toml` + `uv.lock`, no Justfile | `uv run ruff check {files} && uv run mypy {files}` | `uv run ruff check . && uv run mypy src tests && uv run pytest` |
| `python` | `pyproject.toml` only | same, without `uv run` | same, without `uv run` |
| `node` | `package.json` with a `check` script | `npm run check` | `npm run check && npm test` |
| `node` | `package.json` with `lint` + `typecheck` | `npm run lint && npm run typecheck` | `npm test` |
| `bazel` | `MODULE.bazel` or `WORKSPACE` | **no suggestion** | **no suggestion** |
| `unknown` | none of the above | **no suggestion** | **no suggestion** |

## Why Bazel gets no suggestion

Guessing a Bazel target produces failures nobody can explain — a wrong label fails with a
loading error unrelated to the user's change. A quality gate that blocks turns for reasons the
user cannot decode gets switched off within a day, and then protects nothing. `unknown` and
`bazel` both route to: ask the user for the two commands.

## Mutation testing per stack

| Stack | Tool | Why |
|---|---|---|
| Python | `mutmut` | Most actively maintained of the Python options, ~88% detection vs cosmic-ray's ~83%, AST-based so faster, and integrates with pytest without a config ceremony |
| TypeScript / JS | `stryker` | The only mature option |

Always scoped to the diff. Whole-repo mutation runs take hours and nobody waits for them,
which turns the whole idea into a checkbox.

## The measurement rule

Detection ends where measurement begins. `/gauntlet:setup` times the suggested `fast` warm
before writing it, because the per-turn cost is the one number that decides whether the user
keeps the gate armed. A suggestion that takes 90 s is worse than no suggestion — it teaches
the user to set `GAUNTLET=off`.
