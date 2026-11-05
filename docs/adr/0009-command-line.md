# ADR 0009 — The `holmgang` command line

- Status: accepted
- Date: 2026-11-05
- Source: k21; CONTEXT.md §7; ADR 0005 (`bin/holmgang`, `::CLI`), ADR 0006 (report),
  ADR 0008 (evaluation, thresholds left to this slice); cai-platform at `af7561a5`:
  `CLI::Command::Evals::Run`
- Tags: cli, naming, runner, report

## Context

CONTEXT.md §7 names working commands: `holmgang lint <suite>`, `holmgang run --suite …
--target … --variant … --repeat 3 --report out.json`, `holmgang report out/*.json --by
topic`, `holmgang export-yaml`. cai-platform's `evals run` is a `MooseX::App` command over
its database, takes an OpenAI-compatible `--base-url` and `--model`, reads the key from a
`--key-file`, and ends with code 1 when a verdict fails. Holmgang has no database, speaks
every Langertha engine, and has no `::Batch` yet (k15: variants per target, bounded
concurrency, resume). The choices below are the worker's (k21), not the maintainer's.

## Decision

### Shape

- `bin/holmgang` is a thin script: `exit Langertha::Holmgang::CLI->new->run(@ARGV)`.
  `::CLI` (ADR 0005) is a Moose class with `out` and `err` handles, so the commands are
  tested in process; one test runs the script itself for the exit code.
- Options are parsed with `Getopt::Long` (core, `Getopt::Long::Parser`, no global
  configuration), not `MooseX::App`: the sibling dists' executables (`langertha-skeid`'s
  `bin/skeid`) use `Getopt::Long`, and three commands do not need a framework.
- Commands: `lint`, `run`, `report`, `help` (also `--help`, `-h`). Exit codes, the same
  for every command:

| Code | Meaning |
|---|---|
| 0 | everything loaded / ran, every verdict ok |
| 1 | a suite was refused (`lint`), or a verdict is not ok (`run`, `report`) |
| 2 | usage or setup error: unknown option or command, missing argument, a path that is no suite, a target that does not build, a report that does not read or write, a run that aborted |

### `holmgang lint <dir>...`

- Each argument is a suite directory (it holds `suite.yaml`) or a search directory (each
  subdirectory with `suite.yaml` is a suite, in name order).
- Lint is the loader (`Loader->load`, lint and both mock runs included): exactly what
  loads passes, nothing else. A refused suite prints the refusal, which names the case
  file and field; the loader stops at the first refused case, and so does `lint` — a
  second check that went on past it would be a lint the loader does not run.
- Output per suite: `ok <id> (<n> cases)` and `  ok <case-id>` per case, or
  `FAIL <id>` and the refusal; a closing count. To standard output.

### `holmgang run`

    holmgang run --suite DIR [--suite DIR]... --target NAME [--model M] [--url U]
                 [--option K=V]... [--label L] [--variant K=V]... [--repeat N]
                 [--report FILE]

- **A target is a Langertha engine name plus constructor options**, no config file:
  `--target OpenAI` is `Langertha::Engine::OpenAI`, a name with `::` is a class name
  as written (loaded at runtime with `Module::Runtime`, the one runtime-plugin case).
  `--model` and `--url` are the engine's `model` and `url`; `--option K=V` passes any
  other constructor argument. A value that parses as JSON (number, `true`/`false`, an
  object, an array) is that value, else the text as given.
- **No key on the command line.** `--option api_key=…` is refused: argv is visible to
  every user of the host (`ps`). The key comes from where the engine reads it
  (`LANGERTHA_OPENAI_API_KEY` and the like) — the CLI reads no key file and no variable
  itself. There is no default target and no default endpoint: without `--target` the
  command refuses; an engine's own default URL is the engine's.
- **Two network-free targets:** `mock-solution` replays each case's reference solution
  (`Runner->mock_engine($case, 'solution')`), `mock-text` answers text only
  (`'text'`); the dash keeps them apart from every engine name. In the report they are
  `target.engine` `Virtual`, `label` the name. They are the dry run of a suite end to end,
  and what the tests run.
- `--variant K=V` (repeatable, values as for `--option`) become `Target::variant`
  settings, unchecked as that attribute is today; the report's `variant.name` is
  `default` without settings, else the sorted `K=V` pairs joined by `,`. Named variants,
  several variants per target and their checks are k15.
- `--repeat N` (1..100) for every suite; without it each suite's own `repeat`, else 1.
  The loop is sequential (one request at a time), repetition outer, cases in load order,
  no seed sent. Bounded parallel requests and resume are k15 (`::Batch`); this loop is
  private to `::CLI` and goes when `::Batch` arrives.
- One report run per suite (ADR 0006), status `complete`; a case that throws (a program
  error, not a target failure — those are statuses) aborts that suite's run: status
  `aborted`, its error through `Target->scrub`, exit 2 after the report is written.
- Output: one line per case and repetition (`<suite> <case> #<n> <status>`), then the
  evaluation as text (`Evaluation->to_text`), the suites' `threshold` as thresholds.
  `--report FILE` writes the report (outside the checkout, ADR 0003).

### `holmgang report <file>...`

- Reads every file (`Report->read`), builds one `Evaluation` and prints it:
  `--format text` (default), `markdown`, `json`.
- `--by topic` is accepted and the only value: the evaluation is per topic (ADR 0008).
- **Thresholds come from the suites, not the report** (ADR 0008's open question):
  `--suite DIR` (repeatable) loads a suite and takes its `threshold`; without it a verdict
  is judged by its hard cases alone. The report format does not change.
- Exit 1 when a verdict is not ok, as `run` and cai-platform's `evals run`.

### Not now

- `export-yaml`: format 2 is YAML already, so the command only makes sense for DSL
  suites (k18 in progress, export k19 backlog). Left out until k19.
- `--transcript` (`Report::with_transcript`), `--topic`/`--all` selection over search
  directories, cancel on a signal (`cancelled`), named variants, parallel runs, resume —
  k15 or later slices.

## Consequences

- New public names: the module `Langertha::Holmgang::CLI` (already in ADR 0005's table),
  the script `bin/holmgang`, the commands, options and exit codes above, the pseudo
  targets `mock-solution` and `mock-text`.
- k15 replaces the private loop with `::Batch` and extends `--variant`; the option names
  here stay unless its ADR says otherwise.
- `Getopt::Long` joins the cpanfile.
