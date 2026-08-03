---
name: capture
description: Use when a fixture of an EXTERNAL payload is needed - an API response, a provider CSV, a webhook body, a DB row shape - or when provenance.sh denied writing one. Fetches the real thing and writes it alongside a .meta.json recording where it came from. Trigger phrases - "capture a fixture", "/gauntlet:capture", "I need a sample response", "gauntlet blocked my fixture", "add a test fixture for this API".
---

# Capturing a fixture with provenance

You are here because a fixture of an external payload is needed, and `provenance.sh`
requires one thing before it will let you write one: evidence that the payload is real.

## Why this exists

From a production repo's own agent guidelines, written after the fact:

> A parser coded against an ASSUMED upstream CSV schema shipped against columns that
> never existed.

The parser was written against an assumption, and the fixture was written against the *same*
assumption. Every test passed. 100% branch coverage saw nothing, and mutation testing would
have seen nothing either — both check the test against the code, never the code against
reality.

So: **do not write the fixture from what you believe the payload looks like.** Go get it.

## Steps

### 1. Find the real source

In order of preference:

1. **A capture recipe that already exists** — grep the repo for `capture`, `sample`, `fetch`
   in the `Justfile`, `package.json` scripts, and `scripts/`. Reuse beats inventing.
2. **The live endpoint or database** — staging or sandbox credentials, an authenticated
   `curl`, a `psql` query, an `aws s3 cp`.
3. **A payload already committed** somewhere in the repo, or in a sibling repo.
4. **The user.** If nothing above works, ask them to paste or point at a real payload, and
   record where they said it came from. Do not fill the gap with a plausible invention —
   that is the failure this skill exists to prevent.

If the provider ships a schema document, that is not a substitute for a payload. The incident
above happened because a document — or a belief about one — stood in for the bytes.

### 2. Run the capture, do not simulate it

Execute the command for real. Save the output verbatim — do not tidy it, reorder keys,
prettify it, or trim fields that look irrelevant. A fixture's value is that it is not
edited.

**Redact secrets, keep shape.** Replace token and PII values with obvious placeholders
(`"ssn": "XXX-XX-XXXX"`), never delete the keys: a missing key changes the schema, which is
the whole thing under test.

### 3. Write both files, sidecar first

```json
{
  "captured_from": "GET https://api.provider.example/v2/benefits?account=4471",
  "captured_at": "2026-07-27",
  "captured_by": "just capture-provider-benefits 4471",
  "sample_of": "real staging account, edge-case plan with a zero-value field"
}
```

| Field | Rule |
|---|---|
| `captured_from` | the actual origin: method + URL, or the SQL, or the S3 key |
| `captured_at` | the date you ran it, `YYYY-MM-DD` |
| `captured_by` | **must BE a runnable command.** The hook resolves the first token and denies prose. This is the field that makes the claim re-verifiable later |
| `sample_of` | which case this is an instance of — the edge case matters more than the happy path |

If the capture took an ad-hoc command, consider promoting it to a repo recipe
(`just capture-<thing>`) so the next capture is one word and re-verification is trivial.

### 4. Write the fixture

Now the sidecar exists, the hook allows it. If it still denies, the sidecar is missing a
field or `captured_by` did not resolve as a command — the denial message names which.

### 5. Only then write the parser

With the real bytes on disk, write the parser against the file, not against memory. If the
payload contradicts what you assumed, say so out loud — that contradiction is the bug this
whole plugin was built to catch, caught before it shipped.
