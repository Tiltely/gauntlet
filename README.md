<p align="center">
  <img src="assets/banner.gif" alt="gauntlet — inevitable constraints around a coding agent" width="100%">
</p>

# gauntlet

**Skills are intention. Hooks are law.**

A Claude Code plugin that surrounds a coding agent with constraints it cannot talk its way
out of, so you can trust the code without reading every line of it.

> I started coding in the late 60s. My current strategy is to not read any of the code
> written by my agents. That's the only way I can take advantage of their productivity. What
> I do instead is to surround the agents with extreme constraints. […] In the end, I have
> very high confidence in the code they produce because they've had to run the gauntlet of
> all of my constraints and tests.
>
> — Robert C. Martin, July 2026

Process skills already exist for this — TDD, verify-before-completion, test-quality review.
They are *negotiable*: a model can reason its way to why they do not apply this time. A `Stop`
hook that returns `decision: block` cannot be reasoned with.

## What it does

| Hook | Rule |
|---|---|
| `Stop` | The turn does not close while the repo's fast check is red. If the turn touched source, the hook **runs the tests itself** |
| `PreToolUse` | The agent cannot loosen the gate alone — editing the coverage config, the linter config, the workflows, or adding a `skip`/`ignore` marker escalates to your approval |
| `PreToolUse` | No fixture of an external payload without provenance recording where the bytes came from |

Plus three skills: `/gauntlet:setup` to arm a repo, `/gauntlet:run` for the full pre-PR
gauntlet (mutation testing + test-quality audit), `/gauntlet:capture` to fetch a real payload.

## The two ideas worth stealing

**1. Do not detect the lie — refuse to take its word.** The obvious design is a detector: does
the agent claim success without having run anything? It fails both ways. It fires on
legitimate prose ("login works now, try `npm run dev`") and it is evaded by rewording ("I've
finished the changes"). Running the command yourself has no false positives and nothing to
evade.

**2. A prisoner who can edit the bars is not held.** A quality gate the agent can edit is
theatre. Blocked and pressed to finish, the cheapest path out is skipping the test, ignoring
the type, dropping the coverage floor, or deleting the file — all things the agent can write.
`protect.sh` closes that.

Its two verdicts are split on one line: **changes that only make sense to weaken the gate are
denied; edits to gate config for any other reason escalate to you.** Adding a suppression
marker, moving a coverage threshold, gutting a test, `--no-verify`, uninstalling a checker —
these have no common legitimate form, so they are denied outright. Editing `pyproject.toml`
has a thousand honest uses, so that one asks.

The split is not stylistic. Under `defaultMode: "auto"`, a hook's `ask` is resolved by the
auto classifier and may never reach you, while `deny` always lands. **An `ask` that silently
self-approves is worse than no guard** — confidence without protection is the exact failure
this plugin exists to prevent, so the dangerous subset does not depend on it.

## Install

```
/plugin marketplace add Tiltely/marketplace
/plugin install gauntlet@tiltely
/reload-plugins
```

Requires `jq`. Without it the plugin disables itself with one warning per session — it never
fails silently, because silence would read as a passing gate.

Then arm a repo:

```
/gauntlet:setup
```

Nothing gates until that writes `.claude/gauntlet.json`. Opt-in is deliberate: a command
guessed on a repo's behalf produces blocked turns nobody can explain, and a gate the user
cannot decode gets switched off within a day.

## The manifest

```json
{
  "fast": "just check",
  "full": "just check && just test-cov",
  "mutation": "uv run mutmut run --paths-to-mutate {files}",
  "sourcePatterns": ["src/**/*.py"],
  "fixturePatterns": ["tests/**/fixtures/**", "**/*.sample.json"]
}
```

Full field semantics in [`core/manifest.md`](core/manifest.md). **Commit this file** — it is
project configuration, and git-ignored it would leave every new worktree ungated and silent
about it.

## Escaping it

```sh
GAUNTLET=off
```

An environment variable, not a file in the repo: a file is something the agent can create for
itself. Beyond that, the gate gives up after three consecutive blocks — an agent that cannot
fix something in three tries will not fix it in the fourth, and you need to see the turn.

## Verifying the hook payload

The scripts treat every payload field as optional with a conservative fallback, because the
documented `Stop`/`PreToolUse` schema was never observed first-hand at build time. To see the
real shape:

```sh
GAUNTLET_DEBUG=1  # then check ${TMPDIR}/gauntlet-payloads/*.jsonl
```

That caution is not paranoia, it is this plugin's own subject matter: writing a parser against
an assumed schema is exactly the bug `provenance.sh` exists to prevent.

## Two things learned building it

**The guard cannot be live while you build the guard.** A guard's tests and docs necessarily
contain every pattern it matches on, so writing the test for "blocks `--no-verify`" is itself
blocked. This happened four times in a row before the lesson landed. The plugin's own repo is
therefore exempt, detected via its own `.claude-plugin/plugin.json` — so a fork gets the same
exemption and no other repo can claim it by naming a directory.

**Code and prose are different.** Early versions matched their patterns anywhere in a string,
which fired on the same words appearing as *data* — a heredoc, a grep pattern, a commit message
mentioning `--no-verify`. Now: shell patterns anchor to command position, suppression markers
only count in file types where they actually suppress something, and documentation is exempt
from content rules entirely. Prose *about* a marker is not a marker.

## What it does not do

- **Verify external reality.** Provenance makes fabrication expensive, not impossible, and it
  says nothing about provider drift six months later. Re-running a fixture's `captured_by` is
  the upgrade path.
- **Judge whether tests are good, per turn.** That is `/gauntlet:run`, pre-PR, where minutes
  are affordable.
- **Work outside Claude Code.** The hooks are specific to this harness.

## Tests

```sh
sh tests/run-all.sh
```

85 cases. Two groups must never rot:

- **The safeguards** — off switch, retry cap, corrupt manifest, garbage payload. An inescapable
  gate is worse than no gate at all.
- **The false-positive cases** — a cache cleanup, running the tests, prose in a README, a
  marker in a language where it means nothing. A guard that cries wolf is a guard the user
  learns to click through, and then it protects nothing.

## License

MIT © Tiltely LLC
