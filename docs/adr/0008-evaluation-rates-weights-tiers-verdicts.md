# ADR 0008 — Evaluation: rates, weights, tiers, verdicts, comparison

- Status: accepted
- Date: 2026-11-04
- Source: k14; ADR 0005 (`::Evaluation`, weight, tier, hard case), ADR 0006 (statuses,
  what the report leaves to the evaluation); cai-platform `Eval::Batch::by_topic`,
  `Eval::Batch::verdicts`, `t/eval_batch_verdicts.t`, `t/db/eval_batch.t`,
  `docs/entwurf-evals.md` §4.1
- Tags: evaluation, report, status, naming

## Context

A report holds only what was measured (ADR 0006); every derived number — counters, topic
tables, weights applied, curves per length tier, verdicts, pass^k — is computed from it.
ADR 0006 left one question open: how the rates treat the three statuses that are not
measured (`no_vision`, `context_exceeded`, `error`), within the rule that only `passed`
counts as passed. cai-platform's `by_topic` and `verdicts` have no weights and no tiers,
pool the overall row over all cases, and use one run per repetition.

## Decision

### Module and input

`Langertha::Holmgang::Evaluation` (Moose) takes `reports` (one or more `Report` objects,
joined with `Report->merge` first, so nothing counts twice) and optional `thresholds`
(`{ suite_id => { pass_rate, pass_k } }`). A report carries no threshold, so the caller
passes it from the loaded suites; a suite missing there is judged by its hard cases alone.

A **row** is one target and variant: identity is `target` plus `variant` as in the report,
the label shown is `target.label` (else `model`, else `engine`) and `variant.name`. A suite
without a topic is `sonstiges`. Rows appear in the order of the merged runs; topics sort by
id.

### Rates — one denominator

- **Every rate is a weighted share over all results.** A result is one repetition of one
  case that has an entry in the report, whatever its status. The not-measured statuses are
  in the denominator and have not passed — as in cai-platform, where `context_exceeded`
  and `error` count as not passed for rate and pass^k. A target that cannot take the input
  cannot do the task; the counters say why its rate is low.
- **Every status is counted under its own name** (`counts` with all seven, ADR 0006); no
  second rate "over the measured results" exists. The tier curves show `context_exceeded`
  and `error` as their own shares of the same denominator, so hits, context and errors
  stay apart without a second base.
- A missing repetition (cancelled run) is not a result for `rate`; for pass^k it has not
  passed (below).

### Weights

`weight` (ADR 0005, default 1; `null` in a report is 1) multiplies every result of the case
in every share: topic rate, overall's inputs, tier shares, verdict `rate`, `pass_k`,
`pass_any`. Counters (`results`, `counts`, `passed`) stay plain counts; `weight` beside them
is the summed weight. With all weights 1 every number equals cai-platform's.

### Topics and overall

`topics`: per row and topic `suites`, `results`, `weight`, `counts`, `rate`, and `tokens`
(`input`, `output`, `reasoning` summed, `null` when no repetition had a value). `overall`:
per row the **mean of its topic rates** (topics without a rate left out; `null` if none),
plus `topics`, `results` and `counts` summed. *Deliberate difference:* cai-platform's
`gesamt` row is the share over all cases pooled; CONTEXT.md §6 forbids that.

### Length tiers

`tier_curves`: per row, topic and tier, `results`, `weight`, `counts`, `rate`,
`context_exceeded_rate`, `error_rate`. Tiers order `16k`, `48k`, `96k`, `160k`, any other
tier after them by its number. A case without a tier is on no curve. Curves are per topic,
not over all topics, by the same rule as the overall value.

### Verdicts

Per row and suite, in order of appearance: `results`, `counts`, `passed`, `rate`,
`pass_rate`, `k`, `pass_k`, `pass_any`, `pass_k_min`, `case_results`
(`case_id`, `passed`, `repetitions`), `hard_failed` (`case_id`, `forbidden_calls`,
`repetitions`, by case id), `ok` (JSON boolean). The rules are cai-platform's:

- not `ok` when `rate` < `pass_rate` (or no result), when `pass_k` < `pass_k_min` (or no
  case), or when a **hard case** had a forbidden call in any repetition, whatever the rate;
  without a threshold only the hard cases decide;
- `k` is the run's `repeat`; `pass_k` the weighted share of cases (with at least one
  result) passed in all `k` repetitions, `pass_any` in at least one; a missing repetition
  or any status but `passed` has not passed;
- hard is the report's `hard`; where that is `null`, the tags `injection` / `verbot`.

*Renamed from cai-platform:* `runs` (one run per round there) is `k` and, in
`case_results` / `hard_failed`, `repetitions`; `cases` (the number of results) is
`results`. k13 maps these names when it compares.

### Comparison and output

`comparison`: `topics` (column ids) and `rows` (`target`, `variant`, `rates` per topic run,
`overall`). `as_data` / `to_json` give the whole evaluation as one canonical JSON document
`{ holmgang_evaluation: 1, topics, overall, tier_curves, verdicts, comparison }`, the same
bytes for the same reports; `holmgang_evaluation` is raised on the same terms as
`holmgang_report`. `to_text` and `to_markdown` render the comparison, the verdicts (with each
failing hard case) and, when any case has a tier, the tier curves; rates as percentages,
`-` for none. Rates are rounded to four places, as in cai-platform.

## Consequences

- **ADR 0005's module table changes:** the comparison as text, Markdown and JSON is
  `::Evaluation`, not `::Report` — it renders derived numbers, and `::Report` holds none
  (ADR 0006). `::Report` keeps JSON per run, reading and merging.
- `holmgang report` (CLI slice) builds an `Evaluation` from report files and the suites'
  thresholds; it needs the suite directories for those, or the report gains
  `suite.threshold` (a new field, no version raise) — a decision for that slice.
- A new derived number is a new field in this document; a changed meaning raises
  `holmgang_evaluation`.
