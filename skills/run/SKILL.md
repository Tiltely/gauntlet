---
name: run
description: Use before opening a pull request, or when asked whether a change is actually trustworthy. Runs the full gauntlet - the repo's complete check, mutation testing scoped to the diff, and a test-quality audit - and reports which tests verify nothing. Trigger phrases - "run the gauntlet", "/gauntlet:run", "is this ready for a PR", "are these tests any good", "do the tests actually test anything".
---

# The full gauntlet

The per-turn hook answers a cheap question: *is the check green?* This skill answers the
expensive one: *do the tests that make it green actually verify anything?*

Coverage cannot answer that. A test that calls a function and asserts it did not raise
covers every line and verifies nothing. In the pilot repo, a 100% coverage floor
is already enforced — so coverage is the floor here, and this is what stands on it.

Run this before a PR, not per turn. It is minutes, not seconds.

## Steps

### 1. Read the manifest

`.claude/gauntlet.json` at the repo root. No manifest → run `/gauntlet:setup` first.

### 2. The full check

Run `full`. If it fails, stop and report — there is no point mutating a red suite.

### 3. Mutation testing, scoped to the diff

```sh
git diff --name-only $(git merge-base HEAD origin/main)...HEAD
```

Filter to `sourcePatterns`, substitute into `mutation`, run it.

**Scope to the diff, always.** Mutation testing on a whole repo takes hours; on a diff it
takes minutes. If the tool is not installed, install it as a dev dependency (`mutmut` for
Python — most actively maintained, ~88% detection rate, AST-based and faster than the
alternatives; `stryker` for TypeScript) and say that you did.

Report every **survivor**: a mutant the suite failed to kill. Each one is a line where the
code could be wrong and no test would notice. Give file, line, and the mutation that
survived — that triple is the actionable part.

Do not report a survival rate as a score. A percentage invites optimizing the percentage.

### 4. Test-quality audit

Invoke `lens:tdd` in audit mode over the same diff. It catches what mutation testing
structurally cannot: tautological assertions, mock-echo tests (asserting the mock returned
what the mock was configured to return), and tests that mirror the implementation instead of
specifying the behavior.

### 5. Report

Three sections, in this order, most damning first:

1. **Survivors** — file, line, mutation. "This could be wrong and nothing would fail."
2. **Tests that verify nothing** — from the audit, with the reason.
3. **Fixtures without provenance** — any file matching `fixturePatterns` with no
   `.meta.json` sidecar. These predate the hook or arrived from another branch, so they are
   still the unverified shape the hook exists to stop.

Then one line: is this diff trustworthy, yes or no. Say no when it is no.

## What this does not check

External reality. Mutation testing verifies the test against the code; the code against a
real provider's schema is what `provenance.sh` and `/gauntlet:capture` are for. A diff can
pass this entire skill and still parse a CSV whose columns do not exist — that is exactly
how that incident shipped. If the diff touches an external contract, check the fixture's
`captured_at` and re-run its `captured_by`.
