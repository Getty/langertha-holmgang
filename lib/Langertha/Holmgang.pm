package Langertha::Holmgang;
# ABSTRACT: Deterministic tool-use benchmarks for language models via Langertha

use strict;
use warnings;

our $VERSION = '0.001';

1;

=description

Langertha::Holmgang measures language models on B<tasks with tools> and grades
them B<deterministically>: no judge model and no text comparison. A case is a
task in a simulated world; the model works on it through general tools with
real syntax, and the case passes only when the world ends up in the right
state. Any engine that L<Langertha> speaks can be measured.

A I<holmgang> was a Norse duel under fixed rules: a marked-out ground,
witnesses, agreed weapons, and a verdict everyone accepted.

This distribution is under construction. The case DSL, the loader for suite
format 2, the simulators, the runner and the reports arrive in small steps; the
documentation grows with them.

=seealso

=over 4

=item * L<Langertha>

=back

=cut
