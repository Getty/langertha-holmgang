# ADR 0010 — Example suites shipped under `share/suites`

- Status: accepted
- Date: 2026-11-06
- Source: k22; ADR 0003 (engine public, cases private), CONTEXT.md "Engine and cases apart"
- Tags: examples, sharedir, packaging

## Context

ADR 0003 promises a handful of small example suites to learn from, deliberately no real
measurement cases. They should ship in the CPAN distribution and be findable after
installation, so a user can lint and dry-run something without writing a suite first. The
choices below are the worker's (k22), not the maintainer's.

## Decision

- **Place.** Each example suite is a format 2 directory under `share/suites/<id>/`. The
  `[@Author::GETTY]` bundle's `@Basic` already carries `[ShareDir]`, which installs `share/`
  as the distribution's share directory (with `File::ShareDir::Install` as a configure
  requirement); `dist.ini` stays unchanged.
- **Finding them.** No helper and no new public name: after installation the directory is
  `File::ShareDir::dist_dir('Langertha-Holmgang')` plus `suites`; in a checkout it is
  `share/suites`. `File::ShareDir` becomes a runtime requirement so the documented lookup
  works. `holmgang lint <dir>/suites` lints all of them (a directory of suites is accepted
  since ADR 0009).
- **The set.** `demo-linux` (a `linux` device, `run_command` and `write_file`),
  `demo-lamp` (a world without devices, its one tool described by handlers) and
  `demo-haystack` (a message made by `generate`, `::Haystack`, with one planted line).
  Format 2 only; DSL examples follow the DSL (k18). Topic `demo`.
- **No example for an answer-world plugin.** The built-in answer world `kueche` gets no
  example suite: its domain is that of an existing measurement, and even an
  independently invented task there comes too close. A shipped example of a typed answer
  world (`Role::AnswerWorld`) would need a world of its own first.
- **Content.** Freely invented for this distribution — no scenario, prompt, host name,
  solution or seed taken from or modelled on cai-platform's or any private suite. Names
  use `example.org`/`example.net` and the RFC 5737/3849 documentation addresses.
- **Origin and license.** Each `suite.yaml` starts with a comment naming origin, author
  and license, and carries `license: Perl_5` and a `source` with the same.
- **Held by a test.** `t/share_suites.t` loads every shipped suite (lint is part of
  loading) and runs them through the command line: `mock-solution` passes every case,
  `mock-text` fails every case. It reads the `share/` next to `t/`, so it runs from the
  checkout and from the build directory, without a network.

## Consequences

- A change to a simulator or to lint that breaks an example suite fails this repo's tests.
- An example suite is public by design and therefore useless as a measurement; it must
  never be copied into a private suite as a real case.
