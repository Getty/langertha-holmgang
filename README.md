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

> **Status: under construction.** Nothing here is usable yet. Vision,
> vocabulary and scope: [CONTEXT.md](CONTEXT.md). Decisions: [docs/adr/](docs/adr/).

## What it will cover

- Cases and suites written in a small Perl DSL, or loaded from suite format 2
  (`suite.yaml` plus `cases/*.yaml`); both build the same case structure.
- Generators in plain Perl: a fixed seed always yields the same cases.
- Simulators as Moose plugins that execute real commands on the simulated
  state. A command the simulator cannot do is answered like a real system
  would, and recorded as a gap of the simulation, not as a model failure.
- Rules on the end state (`state`, `unchanged_except`, `calls`, `not_called`,
  `only_tools`) and a self-check on every load: doing nothing fails, the
  reference solution and every alternative pass, every wrong solution fails.
- Runs against Langertha engines with variants (thinking on/off, reasoning
  effort, token limits, temperature), tokens per case and turn, repeats and
  resume.
- JSON reports per run and evaluation per category — never one percentage
  over all cases.

## What it does not cover

No judge model, no knowledge tests, no leaderboards, no platform (database,
web UI, users). It never runs commands on real systems. And it ships **no real
benchmark cases**: published cases end up in the training data of the next
models. The distribution brings only a few small example suites to learn from.

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
