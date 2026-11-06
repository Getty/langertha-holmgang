# Langertha-Holmgang

Deterministic tool-use benchmarks for language models, built on
[Langertha](https://metacpan.org/dist/Langertha).

A case is a task in a **simulated world**: servers, networks, databases,
Kubernetes, or a world without devices that only takes answers. The model gets
general tools with real syntax (`run_command`, `write_file`, answer tools) and
has to solve the task with them. Grading looks only at what the model changed:
rules check the **end state** of the world. There is no judge model, no rubric
and no comparison of free text — every correct path to the right end state
counts, and side damage shows up.

Any engine Langertha speaks can be measured: OpenAI-compatible servers
(llama.cpp, vLLM, ...), Anthropic, Ollama and more.

A *holmgang* was a Norse duel under fixed rules — a marked-out ground,
witnesses, agreed weapons, and a verdict everyone accepted.

## Status

**Usable:** suites in format 2 (`suite.yaml` plus `cases/*.yaml`), the loader
with its lint, the simulators (`linux` with many services, `routeros`, `ios`,
the answer world `kueche`, handler worlds without a simulator), grading at the
end state with seven statuses, the runner over any Langertha engine, the JSON
report, the evaluation per topic, and the `holmgang` command line (`lint`,
`run`, `report`).

**Coming:** cases and suites written in a Perl DSL (ADR 0007) —
`Langertha::Holmgang` exports nothing yet. Also not there yet: several
variants per target, parallel requests and resume, and a YAML export.

Vision, vocabulary and scope: [CONTEXT.md](CONTEXT.md). Decisions:
[docs/adr/](docs/adr/).

## Quick start

The distribution ships three small, invented example suites under
`share/suites` (ADR 0010): `demo-linux` (a Linux device), `demo-lamp` (a world
without devices, its tool described by handlers) and `demo-haystack`
(generated input). Installed, they are in the distribution's share directory:

```bash
SUITES="$(perl -MFile::ShareDir=dist_dir -E 'say dist_dir("Langertha-Holmgang")')/suites"
holmgang lint "$SUITES"
```

The rest of this section runs from a checkout, with the dependencies installed
(`cpanm --installdeps .`). `demo-linux` has two cases; its head
(`share/suites/demo-linux/suite.yaml`) names the tools. One case:

```yaml
# share/suites/demo-linux/cases/motd.yaml
id: motd
title: Announce the maintenance window
difficulty: leicht
messages:
  - role: user
    content: "On web-1, make /etc/motd say: Maintenance Saturday 06:00."
state:
  web-1:
    type: linux
    files:
      /etc/motd: "Welcome.\n"
rules:
  - title: motd announces the window
    state: [web-1, files, /etc/motd, content]
    regex: "Maintenance Saturday 06:00"
  - title: nothing else changed
    unchanged_except: [ [web-1, files, /etc/motd] ]
solution:
  - tool: write_file
    args: { host: web-1, path: /etc/motd, content: "Maintenance Saturday 06:00.\n" }
alternatives:
  - title: echo into the file
    calls:
      - tool: run_command
        args: { host: web-1, command: "echo 'Maintenance Saturday 06:00.' > /etc/motd" }
wrong_solutions:
  - title: wrote the wrong file
    calls:
      - tool: write_file
        args: { host: web-1, path: /etc/issue, content: "Maintenance Saturday 06:00.\n" }
```

Lint it — the loader checks every field, then each case checks itself: doing
nothing fails, the reference solution and the alternatives pass, the wrong
solutions fail, and two mock runs over a model engine hold:

```bash
perl -Ilib bin/holmgang lint share/suites/demo-linux
# ok   demo-linux (2 cases)
#   ok hosts-entry
#   ok motd
# 1 suite: 1 ok, 0 refused
```

Run it against the two network-free targets — `mock-solution` replays each
case's reference solution, `mock-text` only answers text — and evaluate the
reports:

```bash
mkdir -p /tmp/reports
perl -Ilib bin/holmgang run --suite share/suites/demo-linux --target mock-solution --report /tmp/reports/solution.json
perl -Ilib bin/holmgang run --suite share/suites/demo-linux --target mock-text     --report /tmp/reports/text.json
perl -Ilib bin/holmgang report /tmp/reports/*.json --suite share/suites/demo-linux
```

```
Comparison by topic (share passed; overall = mean of the topics)
target         variant  demo    overall
mock-solution  default  100.0%  100.0%
mock-text      default  0.0%    0.0%

Verdicts per suite
target         variant  suite       passed  rate    threshold  pass^k  pass^k min  verdict
mock-solution  default  demo-linux  2/2     100.0%  100.0%     -       -           ok
mock-text      default  demo-linux  0/2     0.0%    100.0%     -       -           NOT PASSED
```

To write your own suite, copy one of the examples outside the checkout and
change it; the format is in `perldoc Langertha::Holmgang::Loader` (section
SUITE FORMAT 2).

A real target is a Langertha engine name plus its options; the key comes from
the engine's environment variable, never from the command line:

```bash
perl -Ilib bin/holmgang run --suite share/suites/demo-linux --target vLLM \
  --url http://10.0.0.5:8000/v1 --model some-model \
  --variant 'chat_template_kwargs={"enable_thinking":false}' \
  --repeat 3 --report /tmp/reports/vllm.json
```

Exit codes: `0` all well, `1` a suite refused, a verdict not ok, or a run in
which the target answered no case (every result `error`, `context_exceeded` or
`no_vision`), `2` a usage or setup error. Write reports outside any checkout: a report quotes its cases.

## How it works

- **Suite format 2.** A directory with `suite.yaml` (head, defaults, tools)
  and one file per case under `cases/`. Tools are general: `run_command`,
  `write_file`, the tools of an answer world, or tools described in data by
  handlers. The world is the case's `state`: devices with a `type` that picks
  their simulator, or plain data for handlers. Observations answer diagnostic
  commands whose output lies outside the state.
- **Lint is part of loading.** A case that does not pass its self-check does
  not load.
- **Simulators** are Moose plugins that execute real commands on the
  simulated state, and touch nothing else — no shell-out, no socket, no host
  file. A real command a simulator does not model is answered neutrally and
  recorded as a gap of the simulation (`sim_gap`); a command the simulated
  system does not have gets the real error. A simulator that dies in Perl
  never shows its error to the model.
- **The model sees** only the system prompt, the messages and the tool
  schemas — never the state, the rules, the solutions or the `untrusted`
  marks.
- **Rules** check the end state (`state`, `unchanged_except`, `check`,
  `packet`, `login`) and the calls (`calls`, `not_called`, `only_tools`).
- **Statuses:** `passed`, `failed`, `uncertain` (missed, but a simulation gap
  was hit), `turn_limit`, and the three not measured: `error`,
  `context_exceeded`, `no_vision`.
- **Reports** hold what was measured, per run, case and repetition; the
  **evaluation** derives everything else — rates per topic (never one share
  over all cases), case weights, curves per length tier, verdicts per suite
  against its threshold with pass^k and hard cases, and the comparison of
  targets as text, Markdown or JSON.

## Documentation

The reference is the POD of each module (`perldoc <module>`):

| Topic | Module |
|---|---|
| Overview | [Langertha::Holmgang](lib/Langertha/Holmgang.pm) |
| Command line | [holmgang](bin/holmgang), [Langertha::Holmgang::CLI](lib/Langertha/Holmgang/CLI.pm) |
| Suite format 2 | [Langertha::Holmgang::Loader](lib/Langertha/Holmgang/Loader.pm) (section SUITE FORMAT 2), [::Structure](lib/Langertha/Holmgang/Structure.pm), [::ToolSchema](lib/Langertha/Holmgang/ToolSchema.pm), [::Haystack](lib/Langertha/Holmgang/Haystack.pm) |
| The world, handlers, observations | [::World](lib/Langertha/Holmgang/World.pm), [::Template](lib/Langertha/Holmgang/Template.pm), [::Expectation](lib/Langertha/Holmgang/Expectation.pm) |
| Rules and statuses | [::Grader](lib/Langertha/Holmgang/Grader.pm) (sections RULES and STATUSES), [::Lint](lib/Langertha/Holmgang/Lint.pm) |
| Writing a simulator | [::Role::Simulator](lib/Langertha/Holmgang/Role/Simulator.pm), [::Role::AnswerWorld](lib/Langertha/Holmgang/Role/AnswerWorld.pm), [::Simulators](lib/Langertha/Holmgang/Simulators.pm) |
| Running against engines | [::Runner](lib/Langertha/Holmgang/Runner.pm), [::Target](lib/Langertha/Holmgang/Target.pm) |
| Report and evaluation | [::Report](lib/Langertha/Holmgang/Report.pm), [::Evaluation](lib/Langertha/Holmgang/Evaluation.pm) |

## What it does not cover

No judge model, no knowledge tests, no leaderboards, no platform (database,
web UI, users). It never runs commands on real systems. And it ships **no real
benchmark cases**: published cases end up in the training data of the next
models.

## Development

```bash
prove -lr t/
dzil test
```

## Author

Torsten Raudssus <torsten@raudssus.de>

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
