# ADR 0001 — Sibling distribution and name

- Status: accepted
- Date: 2026-11-04
- Source: the project brief of 2026-11-04
- Tags: distribution, naming, dependencies

## Context

Measuring models with tasks at simulated devices, graded at the end state, is a principle
that works best when it is not bound to one platform — its model client, its database, its
admin UI. Measuring any Langertha engine, writing cases in Perl and sharing the engine as a
CPAN distribution needs it in a dist of its own.

## Decision

- Dist `Langertha-Holmgang`, namespace `Langertha::Holmgang`, repo
  github.com/Getty/langertha-holmgang — the sibling pattern of `langertha-knarr`,
  `langertha-raider` and `langertha-skeid`. The main module `Langertha::Holmgang` carries
  the DSL.
- **Dependency direction is one-way:** Holmgang → Langertha, never back. A model call goes
  through a Langertha engine; tokens come from `Langertha::Usage`. Anything Holmgang needs
  from Langertha and Langertha lacks becomes a card on the langertha board.
- **Holmgang is a generic engine.** It knows nothing about the projects that use it: no
  project name, host, target or suite of a user appears in code, POD, tests or docs. Storage
  of results, display and model catalogues belong to the user; how a project runs Holmgang
  is documented in that project.
- Version line starts at **0.001**.

## Consequences

- A user's repository is never edited from here. Work it needs goes to its own board.
