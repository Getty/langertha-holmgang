# Langertha::Holmgang — CLAUDE.md

Deterministic tool-use benchmarks for language models: cases in a Perl DSL or suite format 2
YAML, simulated worlds, rules graded at the end state, runs against any Langertha engine.
Sibling-dist pattern like `langertha-knarr` / `langertha-raider` / `langertha-skeid`
(`requires 'Langertha'`, never the other way round). Repo: github.com/Getty/langertha-holmgang.

Holmgang is a generic engine. It knows nothing about the projects that use it: no project
name, host, target or suite of a user appears in code, POD, tests, docs or commit messages.
How a project runs Holmgang is documented in that project.

- **`CONTEXT.md`** — vision, vocabulary, scope, acceptance. Read before any non-trivial
  change.
- **`docs/adr/`** — every decision. Anything not recorded there is not decided.
- **karr board** — all open work (`karr list --compact`).

Real benchmark cases never enter this repo (ADR 0003).

Don't create new planning or status files in the repo root: decisions become ADRs, open work
becomes tickets.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself — the
principle is a shared house rule (skilletor bundle `getty-cpan-dist@getty`), the lanes are in
`.claude/rules/holmgang-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `holmgang-worker` (default) |
| Simulators: device types, command grammar, `sim_gap`, answer worlds | `holmgang-sim-worker` |
| Write/extend tests | `holmgang-test-writer` |
| Commits, `Changes`, card → done, pre-release audit | `holmgang-release-manager` |
| Read-only research, audit, gap analysis | `holmgang-worker` ("read-only, change nothing") |

Every subagent is a `holmgang-*` agent — never the built-in `general-purpose`/`Explore`/`Plan`.

The agents carry their skills via `skills:` (see `.claude/agents/`); the main agent
delegates rather than loading them. The skills are installed by skilletor from
`.claude/skilletor.json` (sources getty, karr, langertha) into `.claude/skills/` — gitignored
build artifacts; change a skill in its source repo and `skilletor sync`, never edit the
installed copy. `holmgang-core` is this repo's own skill and tracked here.

## Build and test

Uses the `[@Author::GETTY]` Dist::Zilla plugin bundle.

```bash
prove -lr t/        # recursive: simulator tests live in subdirectories
dzil test           # build and test
```

`LICENSE` is committed (`dzil genlicense`, then `git add LICENSE`); the bundle checks it
against `dist.ini` and gathers only tracked files.
