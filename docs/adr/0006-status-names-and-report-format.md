# ADR 0006 — Status names and report format

- Status: accepted
- Date: 2026-11-04
- Source: karr k11; k27 (status `no_vision`, no images in reports); cai-platform at
  `af7561a5`: `Eval::Grader::grade`, `Eval::Runner::run_case`, `Eval::Batch`,
  `CLI::Command::Evals::Run` (`--report`), `t/eval_context_exceeded.t`
- Tags: report, status, grading, runner

## Context

cai-platform knows four case statuses on the wire (`passed`, `failed`, `ungraded`, `error`)
plus `context_exceeded` since platform#195. Hitting `max_turns` is not a status there: the
grader appends a synthetic, failed rule of kind `turns`, the case becomes `failed` or
`ungraded`, and a separate flag `exceeded` marks it. Its `--report` JSON nests one run per
repetition, per-case numbers (`prompt_tokens`, `completion_tokens`, `prompt_tokens_max`,
`turns`, `duration_ms`, `tool_calls` as a count, `sim_gaps` as bare strings,
`forbidden_calls`, `injection_held`) and derived numbers (`topics`, `verdicts`, counters,
`usage`); rules and the end-state diff live only in the database. k27 adds a target that
cannot see images. The report slice (k12), the runner (k9), the evaluation (k14) and the
acceptance comparison against cai-platform (k13) all need fixed names first.

## Decision

### Statuses

Seven wire names. The first that applies wins:

| # | Wire name | When | Class |
|---|---|---|---|
| 1 | `no_vision` | the case carries an image and the target cannot see it: the capability check, an error signature ("image input is not supported", "not a multimodal model"), or the suite's sight test found the image dropped (k27) | not measured |
| 2 | `context_exceeded` | the target rejected a request because it exceeds its context window | not measured |
| 3 | `error` | the target did not answer for any other reason | not measured |
| 4 | `turn_limit` | `max_turns` model calls without an answer free of tool calls | graded |
| 5 | `passed` | every required rule met | graded |
| 6 | `uncertain` | a required rule missed, a `sim_gap` was hit (in a call or in a rule's check), and no call was forbidden | graded |
| 7 | `failed` | a required rule missed | graded |

- **`turn_limit` is a status of its own.** The rules are still graded and reported as they
  stand at the end state, but no synthetic rule is added; a turn limit is never `passed`,
  `failed` or `uncertain`, with or without a gap.
- `ungraded` is renamed `uncertain`. A forbidden call still makes a missed case `failed`,
  never `uncertain`; a passed case stays passed whatever gaps it hit.
- **Every status is counted under its own name** in every aggregate; none is folded into
  another (cai-platform folds `exceeded` into `failed`/`ungraded`). Only `passed` counts as
  passed — for pass^k too, as in `Eval::Batch::verdicts`. How the rates treat the three
  "not measured" statuses is k14's to fix, within that rule.
- The sight test of k27 is a pre-check per target and suite, never a graded case.

### Report

One JSON document per invocation, UTF-8, `JSON::MaybeXS` with `canonical`, booleans as
`true`/`false`. Every field below is always present; an unknown value is `null`, never
absent and never `0`. The same mock run gives a byte-identical report apart from the fields
marked *volatile*.

```
{ "holmgang_report": 1,
  "generator":   { "holmgang": "<version>", "langertha": "<version>" },   volatile
  "started_at":  ISO-8601, "finished_at": ISO-8601,                       volatile
  "runs": [ <run>, … ] }

<run> = {
  "target":  { "label", "engine", "model", "url" },
  "variant": { "name", "settings": { … } },
  "suite":   { "id", "version", "topic", "digest" },
  "repeat":  n,
  "status":  "complete" | "cancelled" | "aborted",
  "error":   text | null,
  "cases":   [ <case>, … ] }                     in the suite's load order

<case> = {
  "case_id", "title", "tags": [ … ], "tier", "weight",
  "hard": bool, "untrusted": bool,
  "repetitions": [ <repetition>, … ] }           repetition 1..n

<repetition> = {
  "repetition": i, "seed": int | null,
  "status": <wire name>, "score": 0..1, "error": text | null,
  "finish_reason": text | null,                  of the last model response
  "duration_ms": int,                            volatile; sum over the turns
  "rules": [ { "title", "kind", "required": bool, "passed": bool,
               "reason": text, "sim_gap": text | null } ],
  "diff":  [ { "path", "before", "after" } ],    end state against initial state
  "turns": [ { "input_tokens", "output_tokens", "reasoning_tokens",
               "duration_ms", "finish_reason", "calls": n } ],
  "tokens": { "input", "output", "reasoning", "input_max" },
  "calls": [ { "tool", "args", "succeeded": bool, "sim_gap": text | null } ],
  "sim_gaps": [ { "call", "tool", "gap" } ],     call = 0-based index into calls
  "forbidden_calls": int,
  "injection_held": bool | null,                 null without untrusted content
  "transcript": [ … ] | null }                   only on request, otherwise null
```

- **`holmgang_report`** is the format version: an integer, raised on any change a reader of
  the old version would misread (rename, removal, changed meaning). New fields do not raise
  it; readers ignore fields they do not know and refuse a higher version.
- **One run** = one target and variant over one suite with its *n* repetitions (CONTEXT.md);
  the repetitions sit under each case, not in sibling runs. A resumed run fills in the
  repetitions that lack a result.
- **Tokens** come from `Langertha::Usage` per turn: `input_tokens`, `output_tokens`,
  `reasoning_tokens`, each `null` when the target sent none. `tokens` sums the turns per
  field (`null` when no turn had a value); `input_max` is the largest `input_tokens` of one
  turn — the context the case occupied. A turn that hit no target (`no_vision` from the
  pre-check) does not appear in `turns`.
- **The report holds no derived numbers** beyond `score`, `tokens` and the call indices:
  counters, topics, weights applied, curves per tier and verdicts are computed from the runs
  by `holmgang report` (k14), so merging several report files cannot double-count.
- **`tier` and `weight`** are the case's fields as ADR 0005 defines them (`null` / its
  default when the case has none).
- **`target`** never carries a key, a token or credentials in `url`; error texts pass the
  engine's scrubbing first.
- **No image content in a report** — not as base64, not as a `data:` URL. Wherever a message
  with an image appears (`transcript`), the image is `{ "image", "sha256", "bytes" }` (k27).
- `transcript` keeps the messages and tool results without the system prompt, the
  `untrusted` mark stripped as on the wire; the switch that turns it on belongs to k12.
- A report of a private suite is as private as its cases (ADR 0003): rule titles, diffs and
  arguments quote the case. Reports are written outside the checkout, never as fixtures.

### Mapping from cai-platform's `--report`

For the acceptance comparison (k13). cai-platform rows with the same target and suite, in
start order, become repetitions 1..n of one run.

| cai-platform | Holmgang |
|---|---|
| status `passed` | `passed` |
| status `failed` or `ungraded` with `exceeded: true` | `turn_limit` |
| status `ungraded` | `uncertain` |
| status `failed`, `error`, `context_exceeded` | same name |
| — | `no_vision` (no counterpart; k13 compares no case with images) |
| `score` | `score`, after dropping the rule of kind `turns` and recomputing |
| `turns` (count) | number of `turns` entries |
| `prompt_tokens`, `completion_tokens`, `prompt_tokens_max` | `tokens.input`, `tokens.output`, `tokens.input_max`; missing usage there is `0`, here `null` |
| `tool_calls` (count) | number of `calls` entries |
| `sim_gaps` (strings) | `sim_gaps[].gap` |
| `forbidden_calls`, `injection_held`, `duration_ms` | same |
| grading JSON in the database: `rules[].detail`, `required`/`passed` as 0/1, `diff` | `rules[].reason`, booleans, `diff` |
| `target` (label or model), `suite_id`, `topic` | `target.label`, `suite.id`, `suite.topic` |
| `cases_*`, `usage`, `topics`, `verdicts`, `repeat_by_suite` | derived by `holmgang report`, compared there |

k13 compares per target, suite, case and repetition: status after the mapping, each rule's
`passed`, `forbidden_calls`, `injection_held`, and the `sim_gaps` count. Against a mock
target everything else except `duration_ms` must match too; against a real target tokens
and finish reasons are reported, not compared.

## Consequences

- The runner (k9) records per turn and per call, not just sums; `turn_limit` is decided in
  the runner, the grader no longer appends a rule for it.
- Code that compares statuses with cai-platform's names (`ungraded`, the `exceeded` flag)
  goes through the mapping above, never through aliases in the report.
- A new status needs an ADR and raises `holmgang_report` — an old reader would count it
  wrong. `no_vision` is part of version 1 from the start, before k27 lands.

**Amendment 2026-11-04 (k14).** How the rates treat the not-measured statuses is fixed in ADR 0008: every result is in the denominator, only `passed` passes, each status keeps its own counter.
