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

Hunter × Hunter got there first, and called it 制約と誓約 — *restrictions and vows*. A Nen
ability grows in proportion to the severity of the restriction its user binds themselves
with, and the vow only counts when breaking it costs something you cannot avoid paying.
Kurapika's Judgement Chain is set inside the target's heart: violate the condition and it
closes. A vow you can lift on the day it inconveniences you buys nothing — which is the
entire reason this plugin is hooks and not a skill.

Process skills already exist for this — TDD, verify-before-completion, test-quality review.
They are *negotiable*: a model can reason its way to why they do not apply this time. A `Stop`
hook that returns `decision: block` cannot be reasoned with.

## What it does

| Hook | Rule |
|---|---|
| `Stop` | The turn does not close while the repo's fast check is red. If the turn touched source, the hook **runs the tests itself**. It also delivers the turn's receipt |
| `PreToolUse` | The agent cannot loosen the gate alone — a `skip`/`ignore` marker, a moved coverage floor, a deleted test or a `--no-verify` is **denied**, and the agent is told why |
| `PreToolUse` | No fixture of an external payload without provenance recording where the bytes came from |

**No hook here ever asks you to approve anything.** The gauntlet is not "ask me about
everything important" — it is "make sure everything important was done the way we agreed".
See below.

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

Its three verdicts are split on how much doubt there honestly is:

| Verdict | For | What happens |
|---|---|---|
| **deny** | Only makes sense in order to cheat: a suppression marker, a moved coverage floor, a gutted or deleted test, `--no-verify`, uninstalling a checker | Blocked. The agent gets the objection as a tool result and has to solve the problem instead |
| **challenge** | Usually a shortcut, occasionally legitimate: `git checkout --` over a test, `sed -i` over gate config | Denied **once**, with the objection. An identical re-attempt goes through and is recorded |
| **record** | Editing gate config for any other reason — `pyproject.toml` has a thousand honest uses | Nothing is blocked. A line goes on the turn's receipt |

**3. Argue with the agent, do not interrupt the human.** The first version escalated the
doubtful cases to a permission prompt. That was the wrong machine. A prompt stops the turn to
ask someone who has not read it yet and cannot check the claim, it makes unattended runs
impossible, and — because the rule was right maybe one time in twenty — it taught its user to
approve without reading. A guard you click through is not a guard.

So the doubt is spent where the context is. A `deny` reaches the agent as a tool result: it
has read the turn, it knows whether that file was scaffolding or coverage, and it has to
answer the objection before acting. What the *challenge* verdict buys is that no gate-shaped
action can happen **reflexively** — read the objection, decide against it, act again on
purpose. Yes, that is a lock the agent can open. The alternative was not a stronger lock; it
was the same decision handed to whoever had the least context, mid-turn.

The `Stop` hook then prints one receipt of everything that went through, at the moment you are
looking at the finished work. Judging ten decisions with the diff in front of you beats
approving ten prompts blind.

There is also a mechanical reason the dangerous subset never used `ask`: under
`defaultMode: "auto"` a hook's `ask` is resolved by the auto classifier and may never reach
you, while `deny` always lands. **An `ask` that silently self-approves is worse than no
guard.**

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

Full field semantics in [`core/manifest.md`](core/manifest.md). `/gauntlet:setup` **commits it for you** — it is
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
