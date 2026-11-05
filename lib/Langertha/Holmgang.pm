package Langertha::Holmgang;
# ABSTRACT: Deterministic tool-use benchmarks for language models via Langertha

use strict;
use warnings;

our $VERSION = '0.001';

1;

=synopsis

  # lint a suite in format 2: shape checks, the self-check of every case, two mock runs
  holmgang lint /data/suites/demo-motd

  # a dry run without network: the mock model replays every reference solution
  holmgang run --suite /data/suites/demo-motd --target mock-solution --report /data/reports/dry.json

  # a real target: any Langertha engine; the key comes from the engine's environment variable
  holmgang run --suite /data/suites/demo-motd --target vLLM \
    --url http://10.0.0.5:8000/v1 --model some-model --repeat 3 --report /data/reports/run.json

  # evaluate reports per topic
  holmgang report /data/reports/*.json --suite /data/suites/demo-motd --format markdown

=description

Langertha::Holmgang measures language models on B<tasks with tools> and grades
them B<deterministically>: no judge model and no text comparison. A case is a
task in a simulated world; the model works on it through general tools with
real syntax, and the case passes only when the world ends up in the right
state. Any engine that L<Langertha> speaks can be measured.

A I<holmgang> was a Norse duel under fixed rules: a marked-out ground,
witnesses, agreed weapons, and a verdict everyone accepted.

=head1 STATUS

Usable today: suites in B<format 2> (F<suite.yaml> plus F<cases/*.yaml>) with
the loader and its lint, the simulators, the grader, the runner over any
Langertha engine, the JSON report, the evaluation per topic, and the
F<holmgang> command line (C<lint>, C<run>, C<report>).

B<Coming:> cases and suites written in a Perl DSL (ADR 0007). This module
exports nothing yet; C<use Langertha::Holmgang> is the place the DSL will
live. Also not yet there: several variants per target, parallel requests and
resume of a run, a YAML export, and example suites shipped with the
distribution. The distribution ships B<no real benchmark cases>: published
cases end up in the training data of the next models.

=head1 HOW IT FITS TOGETHER

=over 4

=item 1. B<Load.> L<Langertha::Holmgang::Loader> reads a suite directory in
format 2 (the format: L<Langertha::Holmgang::Loader/SUITE FORMAT 2>),
checks every file's shape (L<Langertha::Holmgang::Structure>) and lints every
case (L<Langertha::Holmgang::Lint>). The result is a
L<Langertha::Holmgang::Suite> with its L<Langertha::Holmgang::Case>s. A case
that fails lint does not load.

=item 2. B<Simulate.> Each case starts a fresh L<Langertha::Holmgang::World>
from its initial state. A tool call goes to the case's observations, then to
the simulator of the device's type (L<Langertha::Holmgang::Simulators>,
plugins composing L<Langertha::Holmgang::Role::Simulator> or
L<Langertha::Holmgang::Role::AnswerWorld>), or to the tool's handlers.
Simulators touch only their state: no shell-out, no socket, no host file.

=item 3. B<Run.> L<Langertha::Holmgang::Runner> plays the case against a
L<Langertha::Holmgang::Target> — a Langertha engine plus variant settings —
turn by turn until the model answers without a tool call, C<max_turns> is
reached, or the target fails. The model sees only the system prompt, the
messages and the tool schemas; never the state, the observations, the rules,
the solutions or the C<untrusted> marks.

=item 4. B<Grade.> L<Langertha::Holmgang::Grader> checks the rules at the
end state and on the calls (L<Langertha::Holmgang::Grader/RULES>) and gives
each repetition one status (L<Langertha::Holmgang::Grader/STATUSES>):
C<passed>, C<failed>, C<uncertain>, C<turn_limit>, C<error>,
C<context_exceeded> or C<no_vision>.

=item 5. B<Report.> L<Langertha::Holmgang::Report> writes what was measured
as one JSON document; L<Langertha::Holmgang::Evaluation> derives rates per
topic, weights, curves per length tier, verdicts per suite and the comparison
of targets from one or more reports.

=back

The command line ties these together: L<holmgang>
(L<Langertha::Holmgang::CLI>).

=seealso

=over 4

=item * L<holmgang> — the command line

=item * L<Langertha::Holmgang::Loader> — suite format 2

=item * L<Langertha::Holmgang::Grader> — rules and statuses

=item * L<Langertha::Holmgang::Role::Simulator> — writing a simulator

=item * L<Langertha::Holmgang::Runner> — the model loop

=item * L<Langertha::Holmgang::Report>, L<Langertha::Holmgang::Evaluation> — results

=item * L<Langertha>

=back

=cut
