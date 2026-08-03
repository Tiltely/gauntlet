# Changelog

All notable changes to the gauntlet plugin.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-27

First release. Three hooks and three skills.

### Added

- **`Stop` hook (`gate.sh`)** — the turn does not close while the repo's `fast` check is red.
  One rule, no natural-language heuristics: if the turn touched source, the hook runs the
  command itself. Safeguards: `GAUNTLET=off`, a three-attempt cap so the gate can never
  become an inescapable loop, and exit-0-on-internal-error so the plugin never blocks on its
  own bugs.
- **`PreToolUse` hook (`protect.sh`)** — the agent cannot loosen the gate alone. Two verdicts:
  **`deny`** for changes that only make sense to weaken the gate (adding a suppression marker,
  moving a coverage threshold, gutting a test file, deleting a test, `--no-verify`,
  uninstalling a checker), and **`ask`** for edits to gate config that have legitimate uses
  (`pyproject.toml`, `package.json`, `tsconfig`, workflows, the manifest). The split matters:
  under `defaultMode: "auto"` a hook's `ask` is resolved by the auto classifier and may never
  reach the user, so the dangerous subset does not depend on it.
- **`PreToolUse` hook (`provenance.sh`)** — no fixture of an external payload without a
  `.meta.json` sidecar recording `captured_from`, `captured_at`, `captured_by`, `sample_of`.
  `captured_by` must resolve as a runnable command, so prose ("the user gave me this file")
  is rejected.
- **`/gauntlet:setup`** — detects the stack, measures the candidate command warm before
  committing to it, writes `.claude/gauntlet.json`.
- **`/gauntlet:run`** — the full gauntlet: complete check, mutation testing scoped to the
  diff, and `lens:tdd` audit. Reports which tests verify nothing.
- **`/gauntlet:capture`** — captures a real external payload and its provenance in one step.
- 85 shell tests across the three hooks, run in CI alongside `claude plugin validate` and
  shellcheck.
- **The plugin's own repo is exempt from the content guards**, detected via its own
  `.claude-plugin/plugin.json`. Not a convenience: a guard's tests and docs necessarily contain
  every pattern the guard matches, so with the guard live its own development is impossible.
- **Patterns distinguish code from prose.** Shell patterns anchor to command position, so the
  same words inside a heredoc or a grep pattern do not fire. Suppression markers only count in
  file types where they suppress something (`type: ignore` in a shell script suppresses
  nothing). Documentation is exempt from content rules entirely.

### Design notes

- Opt-in per repo: no `.claude/gauntlet.json`, no gate. A command guessed on a repo's behalf
  produces blocks nobody can explain.
- The protected-artefact list lives in the plugin, not in the manifest. A configurable guard
  is a removable guard.
- The off switch is an environment variable, not a file. A file inside the repo is something
  the agent can create for itself.
- No `SubagentStop` hook: the gate resolves changed files through `git`, not tool authorship,
  so the main turn's `Stop` already covers everything subagents did — and five parallel
  subagents running `mypy` over one `.mypy_cache` produce spurious failures.
- Every payload field is treated as optional with a conservative fallback. The documented
  hook schema could not be observed first-hand at build time, and writing a parser against an
  unverified schema is the exact failure this plugin exists to prevent.
