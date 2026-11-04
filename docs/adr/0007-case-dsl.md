# ADR 0007 — The case DSL: keywords, generators, discovery

- Status: accepted
- Date: 2026-11-04
- Source: k18; ADR 0004 (one structure, two front ends), ADR 0005 (the structure); suite
  format 2 as specified in cai-platform `docs/entwurf-evals.md` §3.1–3.6
- Tags: dsl, naming, generators, loader

## Context

ADR 0004 adds a Perl DSL next to suite format 2; ADR 0005 fixes the structure both build and
puts the DSL into the main module `Langertha::Holmgang`. What is left is the public syntax:
the keywords, how they nest, which Perl names they must avoid, how generators get a seed,
how plugin device types appear, and where DSL suites live. The implementation is a later
slice on top of the loader (k2); the YAML export is k19.

## Decision

### Shape

- **`use Langertha::Holmgang;` exports the keywords** through `Moose::Exporter` (`as_is`;
  `no Langertha::Holmgang;` removes them). No class is built, so there is no `with_meta`:
  the owner of a keyword is the innermost open `suite` or `case` block, not the caller's
  package. A keyword outside its block, or a single-valued keyword given twice, croaks at
  the line that wrote it.
- **Two kinds of names.** *Declarations* (`suite`, `case`, `title`, `rule`, `device`, …)
  record into the open block and return nothing useful. *Constructors* (`at`, `run`,
  `call`, `file`, `haystack`, `handler`, …) are pure: they return a piece of format 2 data
  and record nothing. A constructor checks its own keys at once, so a typo croaks at its
  line.
- **Every keyword is a format 2 key, or sugar with a format 2 image** (table below). The DSL
  builds the same raw hashes the YAML loader reads and hands them to `Structure` (ADR 0005)
  when the `suite` block closes; then lint runs. There is no second validator and no field
  the loader cannot express — a keyword for a new field arrives in the same slice that
  teaches `Structure` the field.
- **Fixed-arity constructors carry prototypes** — `file($)`, `run($$)`, `put($$$)`,
  `call($$)` — so `system_prompt file 'system.md';` does not swallow what follows, and a
  comma list of unparenthesised calls is a compile error instead of a silent misparse.
  Several calls in one list are written with parentheses: `run( a => 'x' ), run( b => 'y' )`.
- **Rule kinds: first argument is the kind's value, then pairs.** `KIND VALUE, %rest` is
  the format 2 rule `{ KIND => VALUE, %rest }`; `rule TITLE => …` adds the title. The pairs
  are format 2's own: expectations and `required => 0`. Expectations are pair keys
  (`equals`, `in`, `exists`, `length`, `any`, `before` …), which `=>` quotes, so none of
  them is exported. A `regex` may be a `qr//`; it is stored as its string form, which Perl
  reads back as the same pattern.

### The keywords

| Keyword | In | Format 2 |
|---|---|---|
| `suite ID => sub {…}` | file | the suite; `id` (must equal the directory name when loaded from a search directory) |
| `title`, `description`, `version`, `topic`, `license`, `repeat` | suite | the key of the same name |
| `threshold pass_rate => …, pass_k => …` | suite | `threshold` |
| `source title => …, license => …, url => …` | suite, case | `source` |
| `system_prompt TEXT` | suite / case | `defaults.system` / `system` |
| `settings temperature => …, max_tokens => …, max_turns => …` | suite / case | `defaults.*` / the case keys |
| `tool NAME => description => …, parameters => {…}, simulator => … \| handlers => […]` | suite | one entry of `tools` |
| `handler match => …, when => …, apply => […], output => …, error => 1` | constructor | one handler; `apply` operations stay data hashes |
| `case ID => sub {…}` | suite, `generate` | one case; `id` |
| `generate seed => N, sub { my ( $rng ) = @_; … }` | suite | plain cases (below) |
| `title`, `difficulty`, `weight` | case | the key of the same name (`weight`: ADR 0005) |
| `tags LIST` | case | `tags`; repeated calls append |
| `tier '48k'` | case | the tag `stufe-48k` (ADR 0005); one per case |
| `ask CONTENT, %opt` | case | a message with `role: user` |
| `message ROLE => CONTENT, %opt` | case | a message; `%opt` is `untrusted => 1` (later `images`, below) |
| `device NAME => TYPE => {…}` | case | `state.NAME` with `type: TYPE` |
| `world NAME => VALUE` | case | `state.NAME` without a type (handler worlds) |
| `observe match => {…}, when => […], output => …, error => 1` | case | one entry of `observe` |
| `rule TITLE => KIND` | case | one entry of `rules` |
| `at PATH, %exp` | constructor | rule kind `state` |
| `unchanged_except [PATHS]`, `calls [CALLS]`, `not_called CALL`, `only_tools [NAMES]` | constructor | the rule kind of the same name |
| `check {host, command}, expect => {…}`, `packet {…}, verdict => …`, `login {…}, result => …` | constructor | the rule kind of the same name |
| `solution CALLS` | case | `solution`; `solution()` is `[]`, the "no tool" family |
| `alternative TITLE => CALLS` | case | one entry of `alternatives` |
| `wrong TITLE => CALLS` | case | one entry of `wrong_solutions` |
| `call TOOL => {ARGS}` | constructor | `{ tool, args }` |
| `run HOST => COMMAND` | constructor | a call of the suite's tool with `simulator: run_command` |
| `put HOST => PATH => CONTENT` | constructor | a call of the suite's tool with `simulator: write_file` |
| `file 'NAME'` | constructor | the file's text, read relative to the suite file's directory |
| `haystack kind => …, tokens => …, seed => …, insert => […], exclude => […]` | constructor | `{ generate: {…} }` long content |

The same constructors build solution calls and the call patterns of `calls`/`not_called`;
as in format 2, the rule reads the arguments as patterns. `run` and `put` resolve their
tool name when the suite closes: exactly one tool with that `simulator` must exist, or the
suite does not load. Paths are dotted text or an array of segments, as in format 2.

### Collisions — decided

- `state` is a feature keyword (`use v5.10` and later): the rule kind is `at`, a world
  entry is `device`/`world`.
- `system` is a builtin: `system_prompt`. `write` is a builtin: `put`.
- `push`, `delete` (handler operations) are builtins: operations stay data hashes, no
  keywords for them.
- `version` shadows the core package in the suite file (`version->parse` there becomes a
  call of the keyword); kept, because format 2 names it so and a suite file has no use for
  the package. Write `version::->parse` if needed.
- `case`, `rule`, `run`, `file`, `tool`, `check`, `call`: no builtin, no `Test::More`
  export — kept. `Test2::V0` exports `call` and `check`, `Path::Class` exports `file`,
  `IPC::Run` exports `run` on request: a file that needs both renames on import
  (`use Langertha::Holmgang call => { -as => 'tool_call' };`, Sub::Exporter under
  `Moose::Exporter`). The house test framework is `Test::More`; nothing to rename there.

### Devices and simulator plugins

There are **no constructors per device type** (no `linux {…}`, `routeros {…}`): the type is
data, `device web1 => linux => {…}`. Keywords exported per registered type would depend on
which plugins were loaded before `use`, and a type name is free to be `link`, `time` or
`dns` — any builtin or user sub. The type is checked against the simulator registry
(`Simulators`, ADR 0005) when the suite closes, as the loader checks it; a plugin from
outside core only has to be registered by then. A plugin may ship its own helper module of
constructors for its state (they return plain hashes its simulator reads); those names are
the plugin's, outside this keyword set.

### Generators

- `generate seed => N, sub {…}` runs its block once, while the suite is built, and passes a
  **private random source** (`Langertha::Holmgang::Random`): a seeded object with a fixed,
  pure-Perl algorithm, so the same seed gives the same cases on every perl and platform.
  Never `srand`/`rand` — the global generator is shared with every other module. Changing
  the algorithm changes every generated suite and needs its `version` raised.
- A generator emits ordinary `case` declarations; nothing about the seed reaches the
  structure. Determinism is tested by generating in two processes with different
  `PERL_HASH_SEED` and comparing the YAML export byte for byte — the test that sees a
  `keys %h` loop in a generator.
- The seed in the file is the default. The loader takes an override per suite id, so a
  private measurement seed never has to be written into a public file (ADR 0003); the
  option's name belongs to the loader/CLI slice.

### Order, errors, checksum

- Cases are ordered by id, as format 2 orders them by file name, so a DSL suite and its
  export run in the same order. A duplicate id refuses the suite.
- Refusals from `Structure` and lint name the suite file, the case id and the field path
  (`suite.pl: case 01-nginx-stopped: rules[1].equals`), like the loader's.
- A DSL suite's checksum is the checksum of its YAML export (k19 makes the bytes
  canonical): a suite and its export are the same suite.

### Where DSL suites live

- A search directory holds suite directories. A suite directory has **either**
  `suite.yaml` with `cases/` **or** `suite.pl`; both is an error, as is a suite id found in
  two search directories. `suite.pl` declares exactly one `suite`, whose id is the
  directory name; fixtures and texts for `file` sit beside it.
- Loading `suite.pl` runs Perl: it is code with the trust of an installed module. The
  loader reads it only from configured search directories, each file compiled in a package
  of its own. Model output never reaches it — the model only talks to simulators.
- `suite` also works outside the loader, in a test or script: it returns the `Suite`
  object, and `file` then reads relative to the calling file.

### Later fields

- **Images** (k27): an `images => [ … ]` option on `ask`/`message`, matching format 2's
  `images: [ { file, untrusted? } ]`, with an `image` constructor if a per-image option
  needs one. Both land with k27's loader change, not before.
- Anything else ADR 0005 or a later ADR adds to the structure gets its keyword in the slice
  that adds it, named in that slice's ADR.

### Example (invented)

```perl
use Langertha::Holmgang;

suite 'example-sums' => sub {
  title   'Example: add numbers, hand in the sum';
  version 1;
  topic   'reasoning';
  system_prompt 'Use the tool to hand in your answer. Then reply briefly without a tool.';

  tool submit_answer => (
    description => 'Hand in the final answer. A later call replaces an earlier one.',
    parameters  => { type => 'object', required => ['value'],
                     properties => { value => { type => 'integer' } } },
    handlers    => [ handler apply => [ { set => 'answer', value => '{value|int}' } ], output => 'ok' ],
  );

  generate seed => 4711, sub {
    my ( $rng ) = @_;
    for my $n ( 1 .. 3 ) {
      my @terms = map { $rng->int( 10, 99 ) } 1 .. 4;
      my $sum = 0;
      $sum += $_ for @terms;
      case sprintf( 'sum-%02d', $n ) => sub {
        title      'Sum of four numbers, variant '.$n;
        difficulty 'leicht';
        world answer => undef;
        ask 'Add '.join( ', ', @terms ).' and hand in the sum.';
        rule 'sum handed in'      => at 'answer', equals => $sum;
        rule 'nothing else moved' => unchanged_except ['answer'];
        solution    call submit_answer => { value => $sum };
        alternative 'corrected answer' =>
          call( submit_answer => { value => $sum - 1 } ), call( submit_answer => { value => $sum } );
        wrong 'off by one' => call submit_answer => { value => $sum + 1 };
      };
    }
  };
};
```

## Consequences

- The DSL slice depends on k2 (`Structure`, loader) and the registry of k3; its tests port
  nothing from cai-platform (there is no DSL there) and pin: every keyword against the
  format 2 hash it must produce, every collision above, croak locations, and generator
  determinism across processes.
- Acceptance 3 (k20) writes one suite in both forms; the export (k19) is the bridge and
  must round-trip DSL → YAML → loader to the same structure.
- New keywords need an ADR; a keyword without a format 2 image is a defect.
