# ADR 0005 — Internal case structure and module layout

- Status: accepted
- Date: 2026-11-04
- Source: k1; suite format 2 as existing suites write it
- Tags: format, structure, layout, naming, simulators

## Context

ADR 0004 makes the internal case structure the contract: the format 2 loader and the DSL
both build it, and lint, runner, grader and report only ever see it. It has to be designed
from format 2, because the existing cases load unchanged. The ports that follow
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
DSL cannot build. Lint runs after the shape check on every load, from either front
end.

Field names are format 2's, unchanged. The structure:

- **Suite** — `id` (`[a-z0-9-]`, the directory name for format 2), `topic` (default
  `sonstiges`), `version`, `title`, `description`, `license`, `source`
  (`title authors license url location`), `threshold` (`pass_rate`, `pass_k`), `repeat`
  (1..100), `defaults` (`system`, `temperature`, `max_tokens`, `max_turns`), `tools`, the
  `cases` in file-name order, and the `checksum` over the files and generated texts.
  `format: 2` is a property of the YAML file, not of the structure; format 1 is refused.
- **Tool** — `name`, `description`, `parameters` (the JSON Schema subset format 2 allows, nothing
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
  family.
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

| Package | Does |
|---|---|
| `Langertha::Holmgang` | the DSL (keywords: ADR 0007) |
| `::Suite`, `::Case` | the structure above (Moose) |
| `::Structure` | shape checks and normalisation for both front ends |
| `::Loader` | format 2 from search directories, `select_suites`, duplicate ids, checksum, YAML export |
| `::Error` | the loud refusal (field path, reason) |
| `::Random` | the seeded private random source for generators (ADR 0007) |
| `::Haystack` | `generate` long contents, deterministic |
| `::World` | state, tool dispatch (observations → simulator → unknown host → handlers), handlers' `apply`, paths, end-state diff, `covered` |
| `::Expectation` | the expectations, shared by rules, `when` and `check.expect` |
| `::Template` | Kolon output templates (`Text::Xslate`; `re`, `cap`, `has`, `pad`, `nft_verdict` through the `Simulators` registry) |
| `::ToolSchema` | the JSON Schema subset of format 2, at load and per call |
| `::Role::Simulator` | the plugin role of a device simulator |
| `::Role::AnswerWorld` | the plugin role of a world with its own tools |
| `::Simulators` | registry: device `type` → simulator; dispatch, `prepare` |
| `::Shell` | the bash grammar (words, chains, pipes, redirects) |
| `::Shell::Filter` | the text filters behind a pipe (`grep`, `tail`, `cut`, `awk`, `tr` …) for simulators and observations |
| `::Sim::Linux` | device type `linux` |
| `::Sim::Linux::<Part>` | the Linux simulator's parts: `Nft`, `Calendar`, `Accounts`, `Backup`, `Dns`, `Docker`, `Git`, `Helm`, `Http`, `Kubernetes`, `Logrotate`, `MariaDB`, `Monitoring`, `Nginx`, `Pki`, `Postfix`, `Postgres`, `Redis`, `RedisService`, `SshAccess`, `Sshd`, `Storage` |
| `::Sim::RouterOS`, `::Sim::IOS` | device types `routeros`, `ios` |
| `::Sim::Kueche` | answer world `kueche` |
| `::Grader` | rules at the end state, score, `forbidden_calls`, `injection_held`, replay |
| `::Lint` | the self-check incl. the two mock runs |
| `::Target` | a Langertha engine plus variant settings |
| `::Runner` | the model loop of one case over a Langertha engine, `max_turns`, `context_exceeded` |
| `::Batch` | suites × targets × `repeat`, bounded concurrency, resume |
| `::Evaluation` | per topic, weights, `verdicts` against `threshold`, hard cases |
| `::Report` | JSON per run; comparison as text, Markdown, JSON (fields: ADR 0006) |
| `::CLI` | the `holmgang` command |

Mock targets are `Langertha::Engine::Virtual`. Generators that produce real cases stay with
those cases (ADR 0003); the DSL gives generators their seed and structure.

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
- `weight` is the one addition to format 2; an older format 2 loader would refuse it.
- `CONTEXT.md` lists five rule kinds; format 2 has eight (`check`, `packet`, `login` in
  addition). This ADR is the authority until `CONTEXT.md` is updated.
- New public names beyond this table (a further module, a structure field) need their own
  ADR.

**Amendment 2026-11-04 (k18).** The World description above is too narrow: format 2 also allows top-level state entries without a `type` (handler worlds), which ADR 0007 covers with `world NAME => VALUE`. `Langertha::Holmgang::Random` (ADR 0007) joins the module table.

**Amendment 2026-11-04 (k16).** `::Target` has two attributes, `engine` (any Langertha engine with `chat_f`) and `variant` (a HashRef of `chat_f` options added to every turn, winning over the turn's own (a variant `max_tokens` beats the case's); k15 names and checks them). One turn is `chat_turn_f(%chat_f_options)`: a Future that is always done, with `{ response, error, error_class }`, `error_class` being `undef` or one of the ADR 0006 wire names `no_vision`, `context_exceeded`, `error`. `classify_error($text)` reads the class off Langertha's error text, `no_vision` first (ADR 0006 order). The context signatures are matched against Langertha's croak text; the `no_vision` signatures are k27; and the body Langertha cuts at 500 characters is raised to 65536 with `local` around the call, which holds only for synchronous transports (Virtual, the LWP fallback) — under a real event loop the cut stays until Langertha keeps the body uncut.

**Amendment 2026-11-04 (k14).** The comparison as text, Markdown and JSON lives in `::Evaluation`, not `::Report` (ADR 0008): it renders derived numbers, which `::Report` never holds.

**Amendment 2026-11-05 (k9).** `::Runner` has two attributes, `target` (a `::Target`) and `grader`. `run_case_f($case, seed => …, repetition => …)` is the model loop over `Target::chat_turn_f` and returns a Future of the result in exactly the per-repetition shape `Report::add_run` takes (plus `answer` and `state`, which a report drops); `run_case` waits for it. Tool results go back through the engine's own `format_tool_results`, so the loop is the same for every wire Langertha speaks. `mock_engine($case, 'solution' | 'text')` is the `Langertha::Engine::Virtual` mock target, and `lint_mock_runs` is the code reference for `Lint`'s `mock_runs`; the loader's default lint carries it, so the two mock runs of the lint run on every load (CONTEXT.md §4) — no default loader loads a case that fails them. Details: a turn limit is the status `turn_limit` with no error text (ADR 0006); a failed request is a turn (tokens `null`); `temperature` is sent only to an engine that `supports('temperature')` (Langertha drops it with a warning otherwise); the error text is Langertha's, without the `Ziel: ` prefix and unscrubbed (Langertha has no scrubber yet, langertha k389); there is no `keep_reasoning` switch — the reasoning fields go back as the engine's `format_tool_results` echoes them; arguments that do not decode get the world's refusal; the mock model estimates no tokens and emulates no context window (a Virtual gap, langertha k389). The run over a suite (resume, cancel) is `::Batch` (k15).

**Amendment 2026-11-05 (k35).** `::Lint` checks the argument filters before the templates: every `{name|filter}` in the path, `value`, `at`, `from` and `to` of a handler's change and in the `when` paths of handlers and observations must be one of `split`, `int`, `lc`, or the case does not load. `Expectation::filter_value` dies on an unknown filter with the world's generic refusal (`dieser Aufruf ist in diesem Szenario nicht vorgesehen.`), naming neither filter, file nor line, because the text reaches the model as a tool result. An error naming the filter would reach the model. Existing suites load unchanged.

**Amendment 2026-11-05 (k38).** `::Target` gains `scrub($text)` (also callable on the class, then without the key), and `chat_turn_f` returns its `error` through it; the class is still read off the raw text first. This supersedes "unscrubbed" in the k9 amendment; the text stays without the `Ziel: ` prefix, since the status already says the target failed. Neither the installed Langertha 0.504 nor the dev Langertha 0.505 ships a scrubber (langertha k389), so the cpanfile floor stays at 0.504. What goes is listed in the module's POD: the engine's `api_key` wherever it stands (a key shorter than 4 characters is left alone), die and Carp locations anywhere in the text (before, only a trailing one was cut), URL userinfo and secret query parameters, `Authorization`/`Bearer`/`api-key` values, the key shapes of common providers, and absolute host paths (`<path>`); the status line, the provider's reason and a URL's host and path stay. The patterns beyond the key are there because Langertha's error text can carry a server's echo and Perl locations. The cut at 2000 characters belongs to the report writer and the batch (k12, k15). Once Langertha ships a scrubber, `scrub` calls it first.

**Amendment 2026-11-11 (k28).** The `::Template` row gains `nft_verdict($device, \%packet)`: existing cases use it in their templates, so it stays. It asks `Simulators::packet_verdict` (the registry), never `Sim::Linux::Nft` directly — the plugin boundary above holds for templates too — and answers `''` when the device's simulator cannot.

**Amendment 2026-11-11 (k34).** Public names k2 introduced beyond the table above, checked against the code on 2026-11-11:
- `::Case` — attributes `tools` and `defaults` (the suite's, as context, never copied into the case's own values), `simulators`, `haystack`, and the lazy derived `initial_state` (generated file contents resolved, prepared, the state as written untouched) and `prompt_messages` (role and content only, generated text resolved, no `untrusted` mark); methods `effective($setting)` (own → suite `defaults` → built-in), `effective_weight` (`weight` or 1), `tag_list`, `tier`, `is_hard`, `has_untrusted`, `no_tool` (`solution: []`).
- `::Structure` — attributes `simulators`, `haystack`; methods `valid_id($id)`, `suite_head($head, dirname => …, format => …)`, `tool($tool, $field)`, `generated($case_data, $file)` (the generated texts the digest takes), `case($data, file => …, tools => …, defaults => …)`.
- `::Lint` — attributes `grader` and `mock_runs` (a code reference `$code->($lint, $case, $field)`, predicate `has_mock_runs`; without it the mock runs do not run); method `lint($case, $field)`.
- `::Grader` — the outcome `grade` takes is `{ state, calls, error, error_class, turn_limit }`; `error_class` is `Target`'s class (`no_vision`, `context_exceeded`, `error`) and `turn_limit` a flag the runner sets (ADR 0006).
- `::Loader` — `list` returns one hash per suite with the keys `id`, `version`, `title`, `description`, `topic`, `cases` and `tools` (counts), `digest` (k30), `error`.
- `::Template` keeps package state: `our $SIMULATORS`, set with `local` for each `render` call to the registry `nft_verdict` asks. A deliberate deviation from the house rule "no package-level state but true constants": the Xslate compiler and its function table are built once per process, and a function has no other way to reach the registry of the current call; `local` keeps it scoped to the render.

**Amendment 2026-11-11 (k30).** One name for the suite's SHA-256 over its files and generated texts: **`digest`**. `Suite` has the attribute `digest` (was `checksum`), `Loader::list` the key `digest`, and the report keeps `suite.digest` (ADR 0006). Chosen by the worker in the overnight run, not by the maintainer: `digest` is the name that already has readers outside this code — the report wire format of ADR 0006 — while `checksum` had only in-dist callers in an unreleased version. No alias for `checksum` is kept: nothing outside the dist uses it. "Checksum" in the structure and module table above, and in ADR 0007 ("Order, errors, checksum"), means this `digest`.

**Amendment 2026-11-11 (k33).** `Loader::list` leaves out a directory whose `suite.yaml` names its `format` with something other than a number — another kind of corpus (a `format` with a name, say), which measures something else than a model. A numeric format other than 2 (`1`, `3`), no format at all, or an unreadable head stays in the list with its error, as before: that is a suite meant for Holmgang that does not load. `load` refuses all of them. Chosen by the worker in the overnight run: skipping, because an error entry for a corpus that never was a suite is noise in every `holmgang list`; filtering on "not a number" rather than on a name, because the engine should not know any user's corpus names, and a numeric format is this lineage's version, whose mismatch should stay visible.

**Amendment 2026-11-11 (k36).** `Case::tier` returns `undef` (not an empty list) without a tier tag, so `{ tier => $case->tier }` keeps its pairs. `Case::report_meta` builds the case meta `Report::add_run` takes (`case_id`, `title`, `tags`, `tier`, `weight` as `effective_weight`, `hard`, `untrusted`) — the one place that maps a case onto the report's case fields; the CLI and the runner test use it.

**Amendment 2026-11-11 (k31).** `ToolSchema::schema_errors` checks `const` per call (compared like `enum`, through `same_scalar`; to the model: `<path>: erlaubt ist <value>`), and `check_schema` refuses a `const` that is not a text, number or boolean. Chosen by the worker in the overnight run, not by the maintainer. The schema the model sees means what it says. Existing suites load and mock-run unchanged.

**Amendment 2026-11-11 (k37).** `Runner::run_case_f` refuses (croaks before the first request) an engine with a defined `system_prompt`: Langertha prepends it as a separate system message ahead of the case's, so the model would see a prompt the case does not carry. Chosen by the worker in the overnight run, not by the maintainer: a warning would still let such a run into a report. This supersedes the k9 note that documented the double system message without enforcing anything. Engine prefixes that wrap `_system_messages` without a `system_prompt` are unaffected.

**Amendment 2026-11-11 (k27, images).** Chosen by the worker in the overnight run, not by the maintainer, unless the card says so.
- **Format 2.** A user message takes `images: [ { file, untrusted? } ]` (card): one to four entries, only on `role: user`; `file` relative to the suite directory, no absolute path, no `..` or empty segment, its real path (links resolved) inside the suite's real path; a plain file, PNG or JPEG by its first bytes (`\x89PNG\r\n\x1a\n`, `\xFF\xD8\xFF`, whatever the extension says), at most 2 MiB (2 097 152 bytes, inclusive), with a width and height readable from the PNG `IHDR` or the JPEG frame header. The message's `content` stays required — an image without a question is not a task. `untrusted` on an image makes `has_untrusted` true, like a message's mark.
- **Structure.** `Structure::case` takes `dir` (the suite directory); a case with images without it is refused. New: `image_file($dir, $file, $field)` (the checks above, returns `{ file, path, media_type, width, height, bytes, sha256 }`), the function `image_measure($bytes)` (media type and size from the magic and the header — no image library, nothing decoded), and the constants `$IMAGES_PER_MESSAGE` (4) and `$IMAGE_MAX_BYTES`.
- **Case.** The case keeps `messages` as written. Derived, never written back: `image_files` (the hash above per `file`), `has_images`, and `prompt_messages`, where a message with images has a list as `content`: `{ type => 'text', text }` first, then one placeholder `{ image, sha256, bytes }` per image — the form ADR 0006 fixes for transcripts and reports, so the runner's conversation already is that form. `image_content($file)` reads the bytes when a request is first built, croaks when their SHA-256 is no longer the loaded one, and keeps the `Langertha::Content::Image` for the case's later requests (the lint's mock runs read it at load, so what was linted is what goes out).
- **Digest.** For each image, in message order, `"<case file>: messages[i].images[j]\0"` and `"<file> <sha256> <width> <height>\0"` after the case file's generated texts; a case without images adds nothing, so every suite without images keeps its digest.
- **Runner.** The image goes out only in the request: `run_case_f` hands `chat_turn_f` the conversation with each placeholder replaced by `Case::image_content`, and Langertha serialises it per engine (`Role::Chat` content blocks: OpenAI `image_url` with a data URL, Anthropic `image`, Gemini `inline_data`, Ollama `images`) — no OpenAI part is built here, so the engine's own wire is used. Option `no_vision => $reason` (from the pre-check, ADR 0006): a case with images ends `no_vision` with that error, without a request and without a turn; a case without images ignores it. `mock_engine` applies `Langertha::Role::ImageInput` to its `Virtual` for a case with images (the mock sees what it is sent, so lint and `mock-solution` are not stopped at the wire); without token usage it passes the sight test unmeasured.
- **Target.** `vision_check_f`, `sight_test_image`, `sight_test_min_tokens` (ADR 0006 amendment k27). `Compress::Zlib` becomes a runtime requirement (core) to build the sight test PNG in memory.
- **DSL.** Not implemented yet (k18). ADR 0007's `images => [ … ]` option on `ask`/`message` stays its plan: the DSL must hand `Structure::case` the suite directory as `dir`.

**Amendment 2026-11-11 (k15).** `::Batch` is the run over suites, targets and variants. `new( suites, targets, repeat, resume, on_event )`: each target is `{ engine, target, variants, concurrency }` — `engine` a code reference `( $case, $slot )` or one engine, `target` the report's `{ label, engine, model, url }`, `variants` `[ { name, settings } ]` (default one `default` without settings), `concurrency` the bound (default 1). `run_f` returns a Future of the `::Report`, `run` waits for it (on `IO::Async::Loop` while requests are open; IO::Async stays optional, as in Langertha), `cancel` starts no further case, `report` is the report as it stands. Per target the cases go through `Future::Utils::fmap_void` with `concurrent` = the bound, in the order variant, suite, repetition, case; a case holds a slot `0 .. n-1` and asks the engine code for that slot, so a caller can give each slot its own engine — Langertha's `Net::Async::HTTP` client keeps one connection per host, so concurrent requests on one engine would queue on it. Targets run side by side. `::Target` gains `deadline`, `check_variant($settings, $engine?)`, `for_variant( engine, settings )` and `variant_keys`; `variant` stays the unchecked wire-level HashRef of `chat_f` options, which `for_variant` builds. Chosen by the worker in the overnight run, not by the maintainer:

- **Variant settings, named and checked** (the k16 amendment left this to k15): `enable_thinking` (on/off, true/false, 1/0, a JSON boolean; normalised to a JSON boolean, sent as `chat_template_kwargs.enable_thinking`), `reasoning_effort` (Langertha's `none minimal low medium high xhigh max`, because Langertha passes these on), `max_tokens` (1..9999999), `temperature` (0..2), `deadline` (seconds, above 0, at most 86400). Anything else is refused (`Error` on `variant.<key>`), an empty value names nothing. Only these five: the card names them. Against the engine (when the batch is built, with the engine of the first case on slot 0): `temperature` and `reasoning_effort` only where it `supports` them, `enable_thinking` only on `Langertha::Role::OpenAICompatible`, `deadline` only on an engine with `async_loop` — because Langertha drops what the model does not take with a warning, and a report would then name a variant that never went out.
- **Deadline**: per request, raced in `Target::chat_turn_f` against `delay_future` on the engine's loop; on expiry the request is cancelled and the turn fails `timeout: deadline (N s)`, so the case is `error`. On an engine without a loop the request has finished before `chat_f` returns, so a deadline cannot cut it and is refused. An idle timeout is not a variant setting: it is the engine's own `user_agent_timeout` (a timeout without data on a stream, total on a plain request), reachable as `--option user_agent_timeout=N`.
- **Resume** takes an earlier `::Report`: every repetition it holds a result for, whatever the status, is taken over and not played; a run of it must match a run of the batch by target and variant as the report shapes them and by suite id, with the same suite `digest` (a changed suite is refused) and the same `repeat`. A run the batch does not cover, a case not in the suite, or a run given twice is refused, so resuming never silently drops results. The resumed report's `started_at` is the earlier one's.
- **Errors.** A case that throws aborts its run: no further case of it starts (cases in play finish), status `aborted`, other runs go on. The run's `error` passes `Target::scrub` of the target built for that case (so the engine's key goes too), else the class's `scrub` (ADR 0006 k38 amendment). The cut at 2000 characters that the k38 amendment left to the batch is here, for the run error and every repetition's `error`.
- **Cancel** starts no further case; cases in play finish. A run missing results is then `cancelled`; an aborted run stays `aborted`.
- **Checkpoint.** `report` may be called at any time; a run still in play is `aborted` there with `error` `unfinished: the batch was still running when this report was written`, so a report written mid-run and then cut off by a crash is resumable and never claims `complete`.
- **Memory.** The batch keeps a result without `state`, `answer` and `transcript` — none of them goes into a report it writes (the `with_transcript` report is not wired to the batch).
- **Events.** `on_event` gets `result`, `vision` and `aborted` with `target`, `variant` (name) and `suite`; the CLI prints its lines from them. The vision pre-check (k27) runs once per run — per target, variant and suite — before its cases, with the run's variant.

**Amendment 2026-11-11 (k48).** `ToolSchema::check_schema` takes `type` as one name or as a non-empty list of distinct known names (`type: [string, "null"]`); `schema_errors` passes a value that fits one of them, and tells the model `<path>: erwartet <t1> oder <t2>`. A `null` in `enum` matches a null value and is shown as `null`. Chosen by the worker in the overnight run, not by the maintainer. Existing suites load and mock-run unchanged.

**Amendment 2026-11-11 (k49).** `tolerance` sits beside a numeric `equals` (`equals: 42, tolerance: 0.5`): the value must be a finite number, or numeric text, at most `tolerance` from `equals`, bounds included, with a relative slack of 1e-9 for binary rounding. It qualifies `equals` and is no expectation of its own (`Expectation::@MODIFIERS`; `Expectation::near`), so it works wherever expectations do. The shape check (`Structure`) refuses it without `equals`, with an `equals` that is no number, and when it is no number of 0 or more. Chosen by the worker in the overnight run over `between`/`approx`: one key, read as written. A format 2 extension; no existing case changes.

**Amendment 2026-11-11 (k18).** Public names the DSL slice adds, chosen by the worker in the overnight run (decisions: ADR 0007 amendment k18): `Langertha::Holmgang` exports the keywords of ADR 0007 plus the constructor `image`; `::Random` has `seed`, `next_u32`, `int`, `float`, `pick`, `shuffle`; `::Loader` gains the attribute `seeds` (seed override per DSL suite id) and the method `assemble( head, cases, file, dir, dirname )` — the path from format 2 data that came from somewhere other than YAML files to a linted `Suite`, which the DSL calls when a `suite` block closes; `load`, `list` and `locate` recognise a suite directory with `suite.pl`.

**Amendment 2026-11-11 (k19, k51).** Public names, chosen by the worker in the overnight run (decisions: ADR 0007 amendment k19, ADR 0009 amendment k19/k51): `::Loader` gains the method `export( DIR, ROOT )` (a DSL suite written as format 2 into `ROOT/<id>`, returns that directory); `::CLI` gains `cmd_export_yaml` and the options `--out` and `--seed`. `::Suite` gets a private attribute `_export` (the export's files), no public name.

**Amendment 2026-11-11 (k52, excerpts).** Chosen by the worker in the overnight run, not by the maintainer. Format 2 takes the message part `{ auszug: { datei, von, bis } }`, alone or in a list of parts; existing suites use it.
- **Module.** `Langertha::Holmgang::Excerpt` (English name, as `::Haystack` is; the format 2 key stays `auszug`, ADR 0004): `source( DIR, FILE, FIELD )` (checks and parses a fixture: `head`, `body`, `norms`, `path`, `sha256`), `text( SPEC, FIELD, DIR )`, `expand( CONTENT, FIELD, DIR )` (returns a new list, never changes the content passed in), `files( CONTENT )` (the `datei` of each excerpt, for the export). The fixture form and the text set in are fixed byte for byte — `Titel`, `Auszug: <von> bis <bis>`, `Stand`, then the blocks with the headings in front — so the model sees the same text in every version (checked on a real suite with excerpts: every message's SHA-256 unchanged).
- **Confinement, as for images (k27).** `datei` matches `quellen/[a-z0-9][a-z0-9-]*.txt`, and its real path, links resolved, lies inside the suite's real path; a plain file; UTF-8. Refusals are `::Error`s with the field path below the part: `cases/c1.yaml: messages[0].content[1].auszug.datei` / `.von` / `.bis` / `.<unknown key>`, and the part itself when `auszug` has a sibling key. Texts in English like every Holmgang refusal; the fixture's own errors name its relative file, never a host path. No size limit (the fixtures are the suite author's files).
- **Cache.** The parse is kept per SHA-256 of the file's bytes (at most 16) in an attribute of the `::Excerpt` object, not in package state and not by mtime: the bytes are read anyway, and a changed file can never hit a stale parse.
- **Structure.** New attribute `excerpt`. `Structure::case` sets the excerpts in before `Haystack::resolve` (from `dir`, which images already need); `Structure::generated( DATA, FILE, dir => DIR )` does the same, so a message content with an excerpt is a generated text. The case keeps `messages` as written (the part, not the text); `prompt_messages` carries the text. `Case.pm` is unchanged: its lazy `prompt_messages` builder is never reached for a case `Structure` built.
- **Digest.** The text set in goes into the digest as the generated text of its message (`"<file>: messages[i].content\0"`, its SHA-256), the fixture's bytes do not — a new wording inside a range moves the digest, a change outside every range does not. Suites without excerpts keep their digest.
- **Export.** `Loader::export` writes the part as it is and copies every fixture an excerpt reads, byte for byte under its relative path (as images), nothing else of `quellen/`; `::Suite`'s private `_export` gains `sources`. Round trip tested: same digest, same text sent.

**Amendment 2026-11-11 (k59).** `Structure::case` refuses a state that is not plain data, with the path to the value (`suite.pl: case c1: state.cfg.hooks[1].run`, reason `not data: a code reference …`): anything but texts, numbers, `undef`, unblessed hashes and lists, and `JSON::PP::Boolean`. A code reference, any other object, a scalar or glob reference are refused — including `\0`/`\1`, which the world's JSON copy would take as booleans. Chosen by the worker in the overnight run: the card names the code reference; the other references die in the same copy without a field and have no format 2 image either. YAML cannot produce any of them, so no format 2 case changes.

**Amendment 2026-11-11 (k56).** Chosen by the worker in the overnight run. The tag `ctx-<N>k` (the context window a case is meant for) is not a length tier; the tier still comes from `stufe-<tier>` alone. Reasons and the alternatives considered: ADR 0008, k56 amendment.

**Amendment 2026-11-26 (k74, a dead target).** Chosen by the worker, not by the maintainer. A target that answers every request with an error (a server whose GPU broke answers 500 at once) used to get every remaining case of the batch played against it within minutes, each one an `error`. `::Batch` gains `max_consecutive_errors` (default 10, `0` off, a whole number):
- **The series** is counted per target and variant — over all suites of that variant, because a dead server is dead for every suite — on the results in the order they end (after `Target`'s own retries, so a 429 that the retries got through never counts). Only status `error` adds one; any other status, `context_exceeded` and `no_vision` included, starts it anew: those are answers of a living target. Results taken over by a resume do not count.
- **At N** the target is taken for dead under that variant: no further case of it starts, the cases in play finish and keep their results. Each of its runs that misses results is `aborted` (no new wire name), its `error` `the target failed N cases in a row (status error), so no further case of this target and variant starts; the last error: <text>` — the text is the result's `error`, already through `Target::scrub`, scrubbed again with the target and cut like every run error. A run of that variant that already has every result stays `complete`. A report written mid-batch shows such a run `aborted` with that reason at once, not `unfinished`. Other variants and targets go on.
- **No result for the rest**: the cases not played are missing, not `error`, so the evaluation counts them nowhere (ADR 0008: a missing repetition is not a result for `rate`) and a resume plays them.
- The `aborted` event comes once per target and variant, after the result that completed the series, with `consecutive_errors` (N) besides `error`, `case` and `repetition`; that is how the CLI tells this abort from a program error (ADR 0009 k74 amendment).
- **Resume replays `error`.** This changes the k15 statement above ("every repetition it holds a result for, whatever the status, is taken over"): a repetition with status `error` is no longer taken over but played again, like a missing one. `error` means the target did not answer — nothing was measured, so playing it again loses no measurement, and a resume after a dead target is exactly the case where these results must go. Every other status, `context_exceeded` and `no_vision` included, is taken over as before.

**Amendment 2026-11-26 (k80, a mock with a context window).** Chosen by the worker, not by the maintainer. Whether a suite's length tiers cut at a target's window could only be seen against a real target. The k9 statement "the mock model … emulates no context window" no longer holds:
- **A variant setting, not a CLI option.** `Target::check_variant` knows `context_window` (tokens, 1..9999999). As a variant, several windows run side by side in one run and the report names each (`w16k`, or `context_window=16000` for the unnamed variant), so the tier curve per variant is the curve per window. Against an engine it is accepted only on a `Langertha::Engine::Virtual` (the mock); a real target's window is its server's, and a setting that changes nothing on the wire must not name a variant. It is no request option: `for_variant` leaves it out of `variant`.
- **The engine code gets the settings.** `::Batch` now calls the engine code `( $case, $slot, $settings )` — the variant's checked settings — for the cases, the vision check and the check at build time; a code that builds a mock reads `context_window` from them. One engine object for every case cannot take a window, so `::Batch` refuses `context_window` there. Existing two-argument codes are unaffected.
- **The mock does it, not the target.** `Runner::mock_engine( $case, $mode, context_window => N )` wraps every script entry of the Virtual in a sub that estimates the request first and, above N, answers `error( 400, 'request (<n> tokens) exceeds the available context size (<N> tokens)' )` — llama.cpp's wording, which `Target`'s context pattern already classifies as `context_exceeded` (ADR 0006 k17 note), before any answer or tool call. So the run goes through the real classification path, not a shortcut in `::Target`. The estimate: the text of every message (text parts only, an image counts nothing), the tool calls' names and arguments, and the tool schemas as canonical JSON, each through `Haystack->estimate_tokens` (characters / 3.5 — the measure the haystack sizes its tiers with, so a "16k" haystack case estimates near 16k). Only the prompt counts, not `max_tokens`, as llama.cpp checks it. The haystack class is named once in `Runner::haystack_class`.
