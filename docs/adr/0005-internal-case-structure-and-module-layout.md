# ADR 0005 — Internal case structure and module layout

- Status: accepted
- Date: 2026-11-04
- Source: k1; suite format 2 as specified in cai-platform `docs/entwurf-evals.md` §3.1–3.6
  and implemented in `CAI::Platform::Eval::Suite` (origin/main af7561a5)
- Tags: format, structure, layout, naming, simulators

## Context

ADR 0004 makes the internal case structure the contract: the format 2 loader and the DSL
both build it, and lint, runner, grader and report only ever see it. It has to be designed
from format 2, because the over 200 existing cases load unchanged. The ports that follow
(loader k2, simulator contract k3, the simulator ports) also need fixed package names before
they can start in parallel. Status wire names and report fields are ADR 0006 (k11); DSL
keywords are ADR 0007 (k18).

## Decision

### The case structure

**Suite and case are Moose objects; everything inside them is plain data.** `Suite` and
`Case` are immutable Moose classes with `ro` attributes. State, observations, handlers,
rules, expectations, tool definitions and solution calls stay plain hashes and arrays,
exactly as format 2 writes them. Why: the dist is Moose (runner, simulator plugins), and
two objects give a stable API for derived values (effective settings, length tier, hard
case). The inner parts are open-ended data trees — a device state is whatever its
simulator reads — that the World deep-copies, the grader diffs and the YAML export dumps;
wrapping each rule or expectation in a class would add a second shape to keep in step with
the loader and nothing to gain. The DSL builds the same hashes and calls the same
constructors.

**Validation lives in one module both front ends call** (`Structure`): the strict shape
checks of format 2 — unknown key, wrong type, bad id refuse loudly with the field path.
The DSL cannot produce what the loader would refuse, and the loader accepts nothing the
DSL cannot build. Lint (§3.5) runs after the shape check on every load, from either front
end.

Field names are format 2's, unchanged. The structure:

- **Suite** — `id` (`[a-z0-9-]`, the directory name for format 2), `topic` (default
  `sonstiges`), `version`, `title`, `description`, `license`, `source`
  (`title authors license url location`), `threshold` (`pass_rate`, `pass_k`), `repeat`
  (1..100), `defaults` (`system`, `temperature`, `max_tokens`, `max_turns`), `tools`, the
  `cases` in file-name order, and the `checksum` over the files and generated texts.
  `format: 2` is a property of the YAML file, not of the structure; format 1 is refused.
- **Tool** — `name`, `description`, `parameters` (the JSON Schema subset of §3.6, nothing
  else accepted), and exactly one of `simulator` (`run_command`, `write_file`, or an answer
  world's type) or `handlers` (`match`, `when`, `apply`, `output`, `error`).
- **Case** — `id`, `title`, `tags`, `difficulty` (`leicht` | `mittel` | `schwer`, the
  format 2 values kept as they are), optional `system`, `messages`
  (`role`, `content`, `untrusted`), `state`, `observe` (`match`, `when`, `output`, `error`
  — never `apply`), `rules`, `solution`, `alternatives` and `wrong_solutions`
  (`title`, `calls`), optional `temperature`, `max_tokens`, `max_turns`, `source`.
  A case holds only its own values; the effective value of a setting falls back to the
  suite's `defaults`, resolved by the case, never copied in — so the YAML export writes
  back what was written.
- **Call** — `{ tool, args }`; a solution is a list of calls, `[]` only in the "no tool"
  family (§3.5).
- **Rule** — `title`, optional `required` (default true), and exactly one kind:
  `state`, `unchanged_except`, `calls`, `not_called`, `only_tools`, `check`, `packet`,
  `login` — all eight that format 2 has today. **Expectations** sit on the rule (or under
  `check.expect`, observation and handler `when`): `exists`, `absent`, `equals`, `in`,
  `regex`, `contains`, `excludes`, `length`, `any`, `none`, `before`. Paths stay as
  written (dotted text or list of segments); the World normalises them on use.
- **World** — the case's `state`: devices keyed by host name, each with a `type` that picks
  its simulator; an answer world is an entry with `type: <world>`.
- **Untrusted marks** stay in the structure where format 2 puts them (a message, a state
  hash, a file entry). They are report-only: the runner strips them from what goes out,
  simulators and templates never print them. The case derives `has_untrusted`, which makes
  `injection_held` defined.
- **Generated content** (`{ generate: … }` or a list of parts in a message or file content)
  stays in the structure as the spec; the case resolves it through `Haystack` when the text
  is first needed. The export writes the spec, not the text.
- **Derived from tags, not stored twice:** the **length tier** (`16k`, `48k`, `96k`, `160k`)
  comes from the format 2 tag `stufe-<tier>`; a **hard case** is one tagged `injection` or
  `verbot`. A DSL keyword for either writes the tag.
- **Weight** is new: an optional case key `weight`, a positive number, default 1 (cluster
  size / representatives). It is the one key format 2 gains; it is optional, so no existing
  case changes.
- **Images** (k27, later slice): `images: [ { file, untrusted? } ]` on a user message, the
  file relative to the suite directory. Messages are hashes with a closed key list, so this
  is one more allowed key — nothing in this structure stands in its way.

### Module layout

All under `Langertha::Holmgang::`; executable `bin/holmgang`.

| Package | Does | From cai-platform |
|---|---|---|
| `Langertha::Holmgang` | the DSL (keywords: ADR 0007) | — |
| `::Suite`, `::Case` | the structure above (Moose) | the hashes `Eval::Suite` returns |
| `::Structure` | shape checks and normalisation for both front ends | `Eval::Suite` (`_case`, `_rule`, `_tool`, `_keys_ok` …) |
| `::Loader` | format 2 from search directories, `select_suites`, duplicate ids, checksum, YAML export | `Eval::Suite` (`load`, `locate`, `select_suites`) |
| `::Error` | the loud refusal (field path, reason) | `CAI::Platform::Refusal` |
| `::Random` | the seeded private random source for generators (ADR 0007) | — |
| `::Haystack` | `generate` long contents, deterministic | `Eval::Haystack` |
| `::World` | state, tool dispatch (observations → simulator → unknown host → handlers), handlers' `apply`, paths, end-state diff, `covered` | `Eval::World` |
| `::Expectation` | the expectations, shared by rules, `when` and `check.expect` | `Eval::World` (`condition`, `_check_value`, `element_match`) |
| `::Template` | Kolon output templates (`Text::Xslate`; `re`, `cap`, `has`, `pad`) | `Eval::World` (`render`, `_tx`) |
| `::ToolSchema` | the JSON Schema subset of §3.6, at load and per call | `Eval::Suite` (schema keys), `Eval::World` (`schema_errors`) |
| `::Role::Simulator` | the plugin role of a device simulator | the contract in `Eval::Sim` POD |
| `::Role::AnswerWorld` | the plugin role of a world with its own tools | `tools`/`tool` in `Eval::Sim` |
| `::Simulators` | registry: device `type` → simulator; dispatch, `prepare` | `Eval::Sim` (`%CLASS`, `class_for`, `prepare`, `run_command`, `write_file`, `world_tools`, `tool_call`) |
| `::Shell` | the bash grammar (words, chains, pipes, redirects) | `Eval::Sim::Shell`, `Eval::Sim::shell_words`, `Eval::World` (`_split_chain`, `_pipe_filters`) |
| `::Shell::Filter` | the text filters behind a pipe (`grep`, `tail`, `cut`, `awk`, `tr` …) for simulators and observations | `Eval::Sim` (`filter`, `_cut`, `_awk`, `_tr`) |
| `::Sim::Linux` | device type `linux` | `Eval::Sim::Linux` |
| `::Sim::Linux::<Part>` | the Linux simulator's parts: `Nft`, `Calendar`, `Accounts`, `Backup`, `Dns`, `Docker`, `Git`, `Helm`, `Http`, `Kubernetes`, `Logrotate`, `MariaDB`, `Monitoring`, `Nginx`, `Pki`, `Postfix`, `Postgres`, `Redis`, `RedisService`, `SshAccess`, `Sshd`, `Storage` | `Eval::Sim::<Part>` (same name) |
| `::Sim::RouterOS`, `::Sim::IOS` | device types `routeros`, `ios` | `Eval::Sim::RouterOS`, `Eval::Sim::IOS` |
| `::Sim::Kueche` | answer world `kueche` | `Eval::Sim::Kueche` |
| `::Grader` | rules at the end state, score, `forbidden_calls`, `injection_held`, replay | `Eval::Grader` |
| `::Lint` | the self-check of §3.5 incl. the two mock runs | `Eval::Suite::lint` |
| `::Target` | a Langertha engine plus variant settings | `CAI::Platform::ModelTester` (partly) |
| `::Runner` | the model loop of one case over a Langertha engine, `max_turns`, `context_exceeded` | `Eval::Runner` (`run_case`, `context_exceeded`) |
| `::Batch` | suites × targets × `repeat`, bounded concurrency, resume | `Eval::Batch::run`, `Eval::Runner::run` |
| `::Evaluation` | per topic, weights, `verdicts` against `threshold`, hard cases | `Eval::Batch` (`by_topic`, `verdicts`) |
| `::Report` | JSON per run; comparison as text, Markdown, JSON (fields: ADR 0006) | the platform's stored results |
| `::CLI` | the `holmgang` command | the platform's `evals` commands |

Not carried over: `Eval::FakeTarget` (replaced by `Langertha::Engine::Virtual`) and the
generators `Eval::Gen::*` — they produce real cases and stay with them (ADR 0003); the DSL
gives generators their seed and structure.

### Plugin boundary (what k3 details)

- A simulator is a Moose class composing `Role::Simulator` (commands: `run_command`,
  optional `write_file`, optional `prepare`) or `Role::AnswerWorld` (`tools` with required
  parameters, `tool`), and names its `device_type`. Each call returns output, success, and
  an optional `sim_gap`, as today.
- It gets the device's state and a read-only context (host name, whole state); it changes
  only that device state. No shell-out, socket or host file.
- `Simulators` knows the built-in types (`linux`, `routeros`, `ios`, `kueche`) and takes
  further ones by registration with a class name, loaded at runtime — so a simulator can
  ship outside this dist. No namespace scanning.
- Core never calls into a simulator's parts. The `check` rule runs a command through the
  registry on a copy of the end state; `packet` and `login` rules ask the device's
  simulator through an optional role method (today the Grader calls `Sim::Nft::verdict`
  and `Sim::SshAccess::check` directly). k3 names those methods.
- How a simulator divides itself into parts is the simulator lane's choice; the part
  names above fix only the namespace.

## Consequences

- k2 (loader) builds `Suite`/`Case` through `Structure`; the DSL (ADR 0007) does the same.
  A field one front end can express and the other cannot is a defect.
- The YAML export round-trips: own values only, generate specs, tags for tier and hardness.
- `weight` is the one addition to format 2; cai-platform's loader would refuse it, so a
  suite using it does not load there until cai-platform depends on Holmgang.
- `CONTEXT.md` lists five rule kinds; format 2 has eight (`check`, `packet`, `login` in
  addition). This ADR is the authority until `CONTEXT.md` is updated.
- New public names beyond this table (a further module, a structure field) need their own
  ADR.

**Amendment 2026-11-04 (k18).** The World description above is too narrow: format 2 also allows top-level state entries without a `type` (handler worlds), which ADR 0007 covers with `world NAME => VALUE`. `Langertha::Holmgang::Random` (ADR 0007) joins the module table.

**Amendment 2026-11-04 (k16).** `::Target` has two attributes, `engine` (any Langertha engine with `chat_f`) and `variant` (a HashRef of `chat_f` options added to every turn, winning over the turn's own, as cai-platform's variant `max_tokens` does; k15 names and checks them). One turn is `chat_turn_f(%chat_f_options)`: a Future that is always done, with `{ response, error, error_class }`, `error_class` being `undef` or one of the ADR 0006 wire names `no_vision`, `context_exceeded`, `error`. `classify_error($text)` reads the class off Langertha's error text, `no_vision` first (ADR 0006 order). Deliberate differences from cai-platform: the context signatures are its `$CONTEXT_RE` unchanged, but matched against Langertha's croak text instead of a separate error and raw body; the `no_vision` signatures are new (k27); and the body Langertha cuts at 500 characters is raised to 65536 with `local` around the call, which holds only for synchronous transports (Virtual, the LWP fallback) — under a real event loop the cut stays until Langertha keeps the body uncut.

**Amendment 2026-11-04 (k14).** The comparison as text, Markdown and JSON lives in `::Evaluation`, not `::Report` (ADR 0008): it renders derived numbers, which `::Report` never holds.
