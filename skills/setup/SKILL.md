---
name: setup
description: Use when arming the gauntlet in a repository for the first time, or when the per-turn gate is too slow, mis-scoped, or firing on the wrong paths. Detects the stack, MEASURES the candidate command before committing to it, and writes .claude/gauntlet.json. Trigger phrases - "set up gauntlet here", "arm the gate", "/gauntlet:setup", "the gate is too slow".
---

# Arming the gauntlet in a repo

The gauntlet is opt-in per repository: with no `.claude/gauntlet.json`, the `Stop` hook
does nothing. That is deliberate — a command guessed on a repo's behalf produces blocks
nobody can explain, which is how a quality gate loses trust permanently.

This skill writes that manifest. **Measure before you write it.** The one number that
matters is how long `fast` takes, because it is paid at the end of every single turn.

## Steps

### 1. Detect

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/detect.sh" "$(git rev-parse --show-toplevel)"
```

It prints a suggested manifest and a `_stack` marker. Treat it as a draft, not an answer.
`_stack: bazel` or `unknown` means there is no suggestion — ask the user for the two
commands rather than inventing them.

### 2. Measure `fast`, twice

```sh
time <fast command>    # cold
time <fast command>    # warm — this is the number that matters
```

Every turn pays the warm number. Judge it:

| Warm time | What to do |
|---|---|
| under 20 s | use it as-is. **Do not build anything.** |
| 20–60 s | scope it down, but see the trap below |
| over 60 s | ask the user: a narrower `fast` (types only? lint only?) or no per-turn gate at all in this repo |

**The scoping trap.** The obvious move — run the checker only on changed files — does not
work for whole-program type checkers. `mypy --strict src/x/y.py` may take *longer* than
`mypy src tests` warm and report different errors, because it has to re-resolve the module
graph from scratch. Same for `tsc`. Measure the narrowed command before believing in it;
`{files}` is worth using for linters (`ruff`, `eslint`) and rarely for type checkers.

### 3. Write the manifest

```json
{
  "fast": "just check",
  "full": "just check && just test-cov",
  "mutation": "uv run mutmut run --paths-to-mutate {files}",
  "sourcePatterns": ["src/**/*.py"],
  "fixturePatterns": ["tests/**/fixtures/**", "**/*.sample.json", "**/*.sample.csv"]
}
```

Read `${CLAUDE_PLUGIN_ROOT}/core/manifest.md` for the field semantics and the glob subset
(brace expansion is not supported — spell the patterns out).

Tell the user this, because it looks like a bug otherwise: **writing this file triggers a
permission prompt.** The manifest is a protected artefact — `protect.sh` escalates every
edit to it, including this one. That is the mechanism working, not a fault.

### 3b. Commit it — do not advise it

An uncommitted manifest arms nobody but the person who wrote it. Untracked files do not
propagate to `git worktree add`, so every worktree starts ungated while the main checkout
looks armed, and a fresh clone gets nothing at all. Telling the user to commit it is
intention, and this plugin exists because intention is not enforcement. **Do it.**

```sh
git add .claude/gauntlet.json
git commit -m "chore: arm the gauntlet gate"
```

Show the commands, then run them. Two situations where you stage only and say which:

- **Unrelated changes are already staged** — committing would sweep them in.
- **The branch is not one to commit to directly** — their default branch with protection
  on it, or a branch that is not theirs.

In both cases add the sentence people misread: **a staged manifest still does not reach a
worktree.** Only a commit does.

Then verify the claim instead of asserting it: `git ls-files .claude/gauntlet.json` must
print the path. Anything else means the gate is armed for this checkout and nothing else.

**Committing is necessary, not sufficient.** The manifest declares what the gate is; the
hooks that enforce it are installed per machine. A teammate without this plugin has no
gate however well the file is committed. Say both halves, or the user will believe one
commit armed the team.

### 4. Verify it actually fires

Make a change that breaks the check on purpose, then end the turn:

```sh
# e.g. append a line that fails the linter to a file matching sourcePatterns
```

The turn must be blocked with the command's real output. If it is not, work down this list:

1. Is the plugin installed and reloaded? (`/plugin`, then `/reload-plugins`)
2. Is `jq` installed? Without it the plugin disables itself with one warning.
3. Is `GAUNTLET=off` set in the environment?
4. Run `GAUNTLET_DEBUG=1` and inspect `${TMPDIR}/gauntlet-payloads/Stop.jsonl` — the hook
   payload's real shape is the one thing the scripts could not verify at build time.

Then revert the deliberate break.

### 5. Offer the collateral work, do not assume it

If `fast` needed a new recipe (`just check-fast`, an npm script), that edit touches the
repo's own build files and lands in a PR. Show the user the diff and let them decide.
