# ADR 0006 — Status names and report format

- Status: accepted
- Date: 2026-11-04
- Source: karr k11; k27 (status `no_vision`, no images in reports)
- Tags: report, status, grading, runner

## Context

A case ends in one of a few outcomes: passed, failed, failed after a simulation gap, the
target did not answer, the input did not fit, too many turns. A turn limit folded into
`failed` with a flag, or counts only in a report, cannot be told apart later; derived
numbers stored next to measured ones drift from them. k27 adds a target that cannot see
images. The report slice (k12), the runner (k9), the evaluation (k14) and the acceptance
comparison (k13) all need fixed names first.

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
  another. Only `passed` counts as passed — for pass^k too. How the rates treat the three
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

## Consequences

- The runner (k9) records per turn and per call, not just sums; `turn_limit` is decided in
  the runner, the grader no longer appends a rule for it.
- No aliases for other names of a status (`ungraded`, an `exceeded` flag) in the report.
- A new status needs an ADR and raises `holmgang_report` — an old reader would count it
  wrong. `no_vision` is part of version 1 from the start, before k27 lands.

**Amendment 2026-11-04 (k14).** How the rates treat the not-measured statuses is fixed in ADR 0008: every result is in the denominator, only `passed` passes, each status keeps its own counter.

**Amendment 2026-11-05 (k38).** Langertha has no scrubbing of its own yet (langertha k389); until it does, "the engine's scrubbing" for error texts is `Langertha::Holmgang::Target::scrub` (ADR 0005, k38), which every repetition's `error` passes. A run-level `error` (k15) goes through the same method.

**Amendment 2026-11-05 (k13).** Acceptance 2 ran against a set of real format 2 suites outside the checkout: a baseline from an independent runner against a mock target, repeat per suite with the round as seed, and `holmgang run --target mock-solution|mock-text` over the same suites, both modes. Per suite, mode, case and repetition the statuses, scores, rules, diffs, calls with arguments and gaps, `sim_gaps`, `forbidden_calls`, `injection_held`, turns and errors are identical, and so are the counters, the verdicts and the rate per topic. What differs, all deliberate (durations aside): rule `reason`s are English (`Grader`, k2 — identical after translating the baseline's fixed phrases); `tokens` are `null` (the mock estimates none, ADR 0005 k9); `seed` is `null` for a suite with `repeat` above 1 (the CLI sends none, ADR 0009); the overall rate is the mean of the topic rates, not a pooled share (ADR 0008).

**Amendment 2026-11-11 (k30).** `suite.digest` stays the field name, and it is now the only name: the suite attribute it comes from and the key of `Loader::list` are `digest` too (ADR 0005, k30), so the value carries one name from the loader to the report.

**Amendment 2026-11-11 (k27, `no_vision` and the sight test).** Chosen by the worker in the overnight run, not by the maintainer; the card's clarification (2026-11-04) fixes that the sight test is a pre-check, not a graded case, and that Langertha's `image_input` and `probe_model_capabilities_f` replace an own `/props` query.
- **Where.** `Target::vision_check_f` is the pre-check of one target; the CLI runs it once per suite that has a case with images, before the suite's cases (not per repetition), prints `<suite> vision check: seen (…) | no_vision -- <reason> | not ruled out -- <note>`, and passes the reason to every case (`Runner::run_case_f` option `no_vision`). Cases without images in the same suite run as usual — `no_vision` is per case with an image (row 1 above), not per suite.
- **Order, first decision wins.** (1) The wire: an engine that does not compose `Langertha::Role::ImageInput` → `no_vision` (a plain `Langertha::Engine::Virtual` is the "mock without vision"). (2) `probe_model_capabilities_f` (a no-op without a metadata endpoint; a failure decides nothing): a learned `image_input => 0` for the engine's `chat_model` → `no_vision`. A static "no claim" decides nothing, because Langertha clears `image_input` for every self-hosted server (vLLM, llama.cpp before the probe) and gateway — treating that as blind would make every self-hosted target `no_vision`. (3) The sight test.
- **The sight test** sends two requests through `chat_turn_f` (the variant applies, `max_tokens` 16): a fixed short text, then the same text with `sight_test_image`, a 512×512 grey checkerboard PNG built in memory. If the image request fails with a `no_vision` signature → `no_vision`. If the image adds fewer than `sight_test_min_tokens` (200, the card's number) input tokens → `no_vision` ("the target drops the image"). The difference of two requests rather than the absolute `prompt_tokens` of one, because a chat template's own preamble can exceed 200 tokens and hide a dropped image; 512×512 so that common vision models spend well above 200 on it (Gemma 3 and InternVL 256, Qwen2.5-VL about 324, LLaVA 576, Pixtral 1024). Known limit: a model that encodes such an image in fewer than 200 tokens (MiniCPM-V style 64-token slices) would be called blind. A target without usage, or a request failing otherwise, decides nothing; the cases then run and show what they get.
- **Report.** The sight test is no case and leaves no repetition; a `no_vision` repetition has the reason as `error`, `turns: []`. A transcript keeps the placeholder `{ image, sha256, bytes }` in the message's `content` list after `{ type: text }`, as above.

**Amendment 2026-11-11 (k15).** A run-level `error` of a batch goes through `Target::scrub`, as the k38 amendment demands, and is cut at 2000 characters; so is every repetition's `error` (ADR 0005 k15 amendment). Run `status` gets no new wire name: a report written while a batch still runs (a checkpoint) has its unfinished runs as `aborted` with the error `unfinished: the batch was still running when this report was written`, a run cut off by a cancel is `cancelled`. A resumed run fills in the repetitions that lack a result and takes the status of the run that resumed it. Chosen by the worker in the overnight run.

**Amendment 2026-11-11 (k57, `difficulty`).** Chosen by the worker in the overnight run, not by the maintainer. `<case>` gains `"difficulty"`: the case's `difficulty` as format 2 writes it (`leicht` | `mittel` | `schwer`), `null` without one; `Case::report_meta` carries it, `Report::add_run` copies it. A new field, so `holmgang_report` stays 1. Unlike every other field it may be **absent** when a report is read — reports written before it came stay readable and read it as `null` (the reader's field spec marks it `optional`; every other field is still required). `Report::merge` takes a `null` difficulty on one side as the other side's value, so an older report merges with a newer one of the same run; two different values still croak as differing case meta. The field is a plain text, not an enum: the loader enforces the three values, and the reader stays as open as for `tier`.

**Amendment 2026-11-11 (k58, acceptance again).** Acceptance 1 and 2 ran again on a newer set of real format 2 suites outside the checkout: 36 suites and 708 cases load with lint green, and per suite, mode (`solution`, `text`), case and repetition statuses, scores, rules, diffs, calls, gaps, `forbidden_calls` and `injection_held` are identical to a baseline made by an independent runner on the same suites, over all 72 suite × mode pairs. Decisions taken with it, by the worker in the overnight run:
- A simulator that dies gives the model `Fehler: interner Fehler beim Ausführen des Aufrufs.` and records the gap `simulator error: <text>` (since k32); a Perl error line a simulator caught and returned is replaced too. The state is kept and the call fails.
- Verdicts carry `unfinished` and `repetitions_error`, see ADR 0008 k58 amendment — `repetitions_error` deliberately does not decide `ok` (ADR 0009 k42).
- Holmgang stores no key anywhere (ADR 0009).
- NUL in a model's text is kept as it is: JSON round-trips it as `\u0000`.
- The mock engine is built per case (`Runner->mock_engine`), so there is no lookup of the case by its messages to get wrong.
- Reports carry topic ids, never display titles of topics.

**Amendment 2026-11-17 (k17, acceptance 4).** Real runs through Langertha against two OpenAI-compatible targets, the suites read in place outside the checkout, reports kept outside it too. Tokens per case and per turn, and the evaluation per topic and difficulty, came out of a run over two suites, concurrency 4. `context_exceeded`: the first target's window held even the 160k tier, so the long cases went to a llama.cpp server with 131072 tokens per slot, `--target OpenAI`, concurrency 1, over the 16k and 160k cases of a long-context suite. The 160k cases all came back as `context_exceeded` within 2.5–3.1 s (llama.cpp rejects before prefill: `request (N tokens) exceeds the available context size (131072 tokens)`, matched by `Target`'s context pattern unchanged), with tokens `null`. The 16k cases were measured, with tokens per turn; reasoning tokens were `null` because llama.cpp reports none. The tier curve shows 160k at 100 % `context_exceeded`, 16k at 0 %. The run's exit 1 came from the verdict (below the suite's threshold), as ADR 0009 says. Measured, for whoever reads the tier names: with that tokenizer the "160k" cases are 169k–245k input tokens and the "16k" cases start at 17k–25k. The tier tag is approximate by design (ADR 0008's note on measured input size). A run against OpenAI's API got only 429 (no credits) for every case: exit 1 by ADR 0009 k42, and the verdict finding became k73.
