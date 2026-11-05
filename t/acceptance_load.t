#!/usr/bin/env perl
# Acceptance 1 (CONTEXT.md): the cai-platform suites load unchanged and their lint
# is green. Runs only against a copy kept outside this checkout (ADR 0003), named by
# HOLMGANG_ACCEPTANCE_SUITES (a search directory, or several separated by ':');
# skips without it. Nothing of the cases is printed — only suite ids and refusals.
use strict;
use warnings;
use Test::More;

use Langertha::Holmgang::Loader;

my $roots = $ENV{HOLMGANG_ACCEPTANCE_SUITES};
plan skip_all => 'set HOLMGANG_ACCEPTANCE_SUITES to a copy of the cai-platform suites' unless $roots;

my $L = Langertha::Holmgang::Loader->new;
my $list = $L->list($roots);
ok( scalar @$list, 'suites found' );
for my $s ( @$list ) {
  if ( $s->{error} && $s->{error} =~ /\Aformat: only format 2/ ) {
    note( $s->{id}.': not a format 2 suite, not measured' );
    next;
  }
  is( $s->{error}, undef, $s->{id}.' loads, lint green' );
}

done_testing;
